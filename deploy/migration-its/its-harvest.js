// ITS assisted harvester — paste this WHOLE file into the DevTools console of a
// real, logged-in app.itsdispatch.com tab (Cloudflare Turnstile blocks every
// automated browser, so the human-driven tab is THE working path — see
// ITS_EXTRACTION.md §4). It enumerates the open+closed boards, ALSO probes
// editId gaps to recover loads that were invoiced (invoiced loads leave the
// board entirely), parses each load with the parser validated live against
// loads 1136 & 1162, and downloads `its-captured-<date>.json`.
//
// Next step on the dev box:  node merge-its.mjs ~/Downloads/its-captured-*.json
// Nothing here touches Truxon prod.
//
// CONFIG — adjust before pasting if needed:
//   FROM   ignore loads whose stops all pre-date this (bulk import covered ≤ Jul 17)
//   MAX_PROBES  0 = BOARD-ONLY (reliable, recommended for a first run). Set >0
//               to also recover invoiced-and-gone loads by probing recent editIds.
//   FLOOR  highest editId already in prod (run its-dryrun.mjs to print it). With
//          MAX_PROBES>0, bounds the probe to (FLOOR, hi]; 0 = use RECENT_WINDOW.
//   RECENT_WINDOW  how far below the newest board id to probe when FLOOR unknown.
(async () => {
  const FROM = '2026-07-10'
  const FLOOR = 0
  const MAX_PROBES = 0            // board-only by default — flip to e.g. 400 once FLOOR is known
  const RECENT_WINDOW = 6000
  const STOP_AFTER = 30 // consecutive blank/old probes ends the probe early

  const D = '/modules/loads/data/edit_data.php'
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
  const fmt = (d) => d.toISOString().slice(0, 10)
  const today = new Date()

  async function boardIds(open_closed) {
    const body = new URLSearchParams({
      searchinput: '', search_filter: 'anything',
      search_from: FROM, search_to: fmt(today),
      show_time: '1', open_closed,
    }).toString()
    const t = await (await fetch('/sections/dispatchboard_list.php', {
      method: 'POST', credentials: 'include',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body,
    })).text()
    return [...new Set([...t.matchAll(/editload\(\s*['"]?(\d+)/g)].map((m) => Number(m[1])))]
  }

  function parseLoad(doc, editId) {
    const val = (n) => { const el = doc.querySelector(`[name="${n}"]`); return el ? (el.getAttribute('value') || '').trim() : '' }
    const disp = (id) => { const el = doc.getElementById(id); return el ? (el.getAttribute('value') || '').trim() : '' }
    const selText = (n) => { const el = doc.querySelector(`select[name="${n}"]`); if (!el) return ''; const o = el.querySelector('option[selected]'); return o ? o.textContent.trim() : '' }
    const stops = []
    for (let i = 1; i <= 20; i++) {
      const shId = val(`sh_id_${i}`), shLoc = val(`sh_location_${i}`), shName = disp(`sh_id_${i}_display`)
      if (shId || shLoc || shName) stops.push({ t: 'pu', name: shName, loc: shLoc, date: val(`sh_date_${i}`), h: val(`sh_hour_${i}`), m: val(`sh_minute_${i}`), ap: val(`sh_am_${i}`), po: val(`sh_po_numbers_${i}`) })
      const coId = val(`co_id_${i}`), coLoc = val(`co_location_${i}`), coName = disp(`co_id_${i}_display`)
      if (coId || coLoc || coName) stops.push({ t: 'del', name: coName, loc: coLoc, date: val(`co_date_${i}`), h: val(`co_hour_${i}`), m: val(`co_minute_${i}`), ap: val(`co_am_${i}`), po: val(`co_po_numbers_${i}`) })
    }
    return {
      meta: {
        loadNum: val('load_number'), editId: String(editId),
        invoiceNum: val('invoice_number') || val('invoice_no') || '', invoiceDate: val('invoice_date') || '',
        listCustomer: disp('customer_id_display'), capturedAt: new Date().toISOString(),
      },
      customer_name: disp('customer_id_display'),
      driver: selText('driver_id'), truck: selText('truck_id'), trailer: selText('trailer_id'), trailer_type: selText('trailer_type'),
      total_rate: val('total_rate'), total_miles: val('total_practical_miles') || val('total_miles'), empty_miles: val('empty_practical_miles') || val('empty_miles'),
      work_order: val('work_order'), status: selText('status'),
      notes: val('load_notes') || val('notes') || val('dispatch_notes') || '',
      stops,
    }
  }

  async function fetchLoad(id) {
    // 8s per-request timeout — a single stalled edit_data.php must never freeze
    // the whole harvest (that was the hang: no timeout on an awaited fetch).
    const ctl = new AbortController()
    const to = setTimeout(() => ctl.abort(), 8000)
    try {
      const html = await (await fetch(`${D}?window_id=0&duplicate=0&id=${id}&dispatch_status=open&pending=0&office_id=0`, { credentials: 'include', signal: ctl.signal })).text()
      return parseLoad(new DOMParser().parseFromString(html, 'text/html'), id)
    } finally { clearTimeout(to) }
  }
  const isRecent = (L) => {
    const dates = L.stops.map((s) => s.date).filter(Boolean)
    return dates.length === 0 || dates.some((d) => d >= FROM)
  }

  console.log(`[harvest] boards ${FROM} → ${fmt(today)} …`)
  const open = await boardIds('open')
  const closed = await boardIds('closed')
  const board = [...new Set([...open, ...closed])].sort((a, b) => a - b)
  console.log(`[harvest] board editIds: open=${open.length} closed=${closed.length} union=${board.length}`)
  if (!board.length) { console.error('[harvest] board came back EMPTY — are you logged in on app.itsdispatch.com?'); return }

  const warnings = [], loads = [], probed = { kept: 0, old: 0, blank: 0 }
  const seen = new Set(board)

  // 1) every board load (already inside the date window by search)
  for (const id of board) {
    try {
      const L = await fetchLoad(id)
      if (!L.meta.loadNum) { warnings.push(`editId ${id}: no load_number parsed (skipped)`); continue }
      loads.push(L)
      await sleep(250)
    } catch (e) { warnings.push(`editId ${id}: ${String(e).slice(0, 80)}`) }
  }

  // 2) probe the gaps — invoiced loads leave the board but edit_data.php still
  //    serves them by id. In-range holes first, then walk downward below the
  //    board floor until FLOOR (if known) or STOP_AFTER consecutive blank/old.
  // ITS editIds are GLOBAL across all Truckstop customers, so Aida's loads are
  // sparse — probing the whole lo→hi span (or downward from an old outlier like
  // still-open load 1136) is a needle-in-haystack that wastes every probe. New
  // invoiced-and-gone loads have RECENT (high) editIds, so probe DOWNWARD from
  // the newest board id, bounded by FLOOR (max editId already in prod; run
  // its-dryrun.mjs to get it). Unknown FLOOR → a recent window. STOP_AFTER
  // consecutive blank/old ends it early. MAX_PROBES=0 → board-only (safest).
  const hi = board[board.length - 1]
  const floorBound = FLOOR > 0 ? FLOOR : hi - RECENT_WINDOW
  const candidates = []
  for (let id = hi - 1; id > floorBound && candidates.length < MAX_PROBES; id--) {
    if (!seen.has(id)) candidates.push(id) // recent → older
  }
  console.log(`[harvest] probing ${candidates.length} recent ids (hi=${hi} floor=${floorBound}, cap ${MAX_PROBES}, timeout 8s each)…`)
  let consecutive = 0
  for (const id of candidates) {
    try {
      const L = await fetchLoad(id)
      if (!L.meta.loadNum) { probed.blank++; consecutive++; }
      else if (!isRecent(L)) { probed.old++; consecutive++; }
      else { loads.push(L); probed.kept++; consecutive = 0 }
      if (consecutive >= STOP_AFTER) { console.log(`[harvest] ${STOP_AFTER} consecutive blank/old — stopping at ${id}`); break }
      await sleep(200)
    } catch (e) { warnings.push(`probe ${id}: ${String(e).slice(0, 80)}`) }
  }

  for (const L of loads) {
    if (!L.stops.some((s) => s.t === 'pu')) warnings.push(`load ${L.meta.loadNum}: no pickup stop`)
    if (!L.stops.some((s) => s.t === 'del')) warnings.push(`load ${L.meta.loadNum}: no delivery stop`)
  }

  console.log(`[harvest] DONE: ${loads.length} loads (board ${board.length}, probe-recovered ${probed.kept}; probes old=${probed.old} blank=${probed.blank})`)
  warnings.slice(0, 30).forEach((w) => console.warn('  warn: ' + w))

  const blob = new Blob([JSON.stringify(loads, null, 1)], { type: 'application/json' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `its-captured-${fmt(today)}.json`
  document.body.appendChild(a); a.click(); a.remove()
  console.log(`[harvest] downloaded ${a.download} — next: node merge-its.mjs ~/Downloads/${a.download}`)
})()

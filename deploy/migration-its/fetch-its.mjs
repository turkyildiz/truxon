#!/usr/bin/env node
// Truxon ITS delta fetcher — logs into ITS Dispatch nightly, enumerates the
// dispatch board (open + delivered), pulls each load's full record, and
// ACCUMULATES them into a local staging file. It NEVER writes to Truxon prod.
//
// Why nightly (not one-shot at cutover): once a load is invoiced in ITS it
// leaves the dispatch board entirely. Capturing every night grabs each load
// while it is still visible, so nothing that was created-then-archived between
// the bulk import and go-live slips through. At cutover we run import.mjs once
// against the accumulated staging file (idempotent — skips load_numbers already
// in prod), so it is a single reviewed step, not a leap of faith.
//
// The extraction path (reverse-engineered 2026-07-19, see ITS_EXTRACTION.md):
//   • Enumerate: POST /sections/dispatchboard_list.php  (open_closed=open|closed,
//     wide search_from/search_to) → regex showFrame_editload('<editId>').
//   • Per load:  GET /modules/loads/data/edit_data.php?id=<editId>&...  →
//     fully-populated editor HTML (session-cookie authed). NOTE: the param is
//     id=, NOT LoadEditID= (LoadEditID returns a blank template).
//   • Parse the static value= attributes + #sh_id_N_display / #co_id_N_display
//     typeahead ids for shipper/consignee names.
// All of this runs inside the logged-in page context (page.evaluate): it
// inherits the session cookie and has native fetch + DOMParser — the exact code
// validated live against loads 1136 (1 stop) and 1162 (1 pickup, 2 drops).
//
// Env (deploy/migration-its/its.env, chmod 600):
//   ITS_ACCOUNT      ITS account number (Aida = IL76053)
//   ITS_USERNAME     ITS username           (or set ITS_EMAIL instead)
//   ITS_EMAIL        ITS login email        (alternate to username)
//   ITS_PASSWORD     ITS password
//   ITS_LOOKBACK_DAYS  board search window, default 120
//   ITS_CAPTURE_DIR    where staging JSON lands, default ./its_delta
//   ALERT_WEBHOOK      optional: watchdog URL for failure email
//   WATCHDOG_REPORT_KEY  optional: watchdog report key
//   SUPABASE_ANON_KEY    optional: bearer for the watchdog verify_jwt gate
//
// Usage:
//   node fetch-its.mjs                 # scheduled run: login, capture, accumulate
//   node fetch-its.mjs --once          # same, but do not merge (write a snapshot only)
//   node fetch-its.mjs --selfcheck     # login + parse a few loads, assert invariants
//   node fetch-its.mjs --login         # persistent-profile manual login fallback
//   node fetch-its.mjs --headed        # run with a visible browser (debugging)

import { chromium } from 'playwright'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const env = loadEnv(join(HERE, 'its.env'))
const LOOKBACK = Number(env.ITS_LOOKBACK_DAYS || 120)
const CAPTURE_DIR = env.ITS_CAPTURE_DIR || join(HERE, 'its_delta')
const PROFILE = env.ITS_PROFILE_DIR || join(HERE, '.its-profile')
const ACCUM = join(HERE, 'its_loads_full.json')
const FLAG = (f) => process.argv.includes(f)
const MODE_LOGIN = FLAG('--login')
const MODE_SELFCHECK = FLAG('--selfcheck')
const MODE_ONCE = FLAG('--once')
const HEADED = FLAG('--headed') || MODE_LOGIN

function loadEnv(path) {
  try {
    return Object.fromEntries(readFileSync(path, 'utf8').split('\n')
      .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  } catch { return {} }
}

const log = (m) => console.log(`[its] ${new Date().toISOString()} ${m}`)
const isoDate = () => new Date().toISOString().slice(0, 10)

async function alert(subject, body) {
  if (!env.ALERT_WEBHOOK || !env.WATCHDOG_REPORT_KEY) return
  try {
    const headers = { 'Content-Type': 'application/json' }
    if (env.SUPABASE_ANON_KEY) {
      headers.Authorization = `Bearer ${env.SUPABASE_ANON_KEY}`
      headers.apikey = env.SUPABASE_ANON_KEY
    }
    await fetch(env.ALERT_WEBHOOK, {
      method: 'POST', headers,
      body: JSON.stringify({ report: { subject, body }, key: env.WATCHDOG_REPORT_KEY }),
    })
  } catch { /* best effort */ }
}

// ── the in-page harvester ───────────────────────────────────────────────────
// Runs in the ITS page context. Returns { boards, loads, warnings }. This is the
// exact logic validated live; keep it self-contained (no closures over Node).
async function harvest(lookbackDays) {
  const D = '/modules/loads/data/edit_data.php'
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

  const to = new Date()
  const from = new Date(to.getTime() - lookbackDays * 86400000)
  const fmt = (d) => d.toISOString().slice(0, 10)

  async function boardIds(open_closed) {
    const body = new URLSearchParams({
      searchinput: '', search_filter: 'anything',
      search_from: fmt(from), search_to: fmt(to),
      show_time: '1', open_closed,
    }).toString()
    const t = await (await fetch('/sections/dispatchboard_list.php', {
      method: 'POST', credentials: 'include',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body,
    })).text()
    return [...new Set([...t.matchAll(/editload\(\s*['"]?(\d+)/g)].map((m) => m[1]))]
  }

  function parseLoad(html, editId) {
    const doc = new DOMParser().parseFromString(html, 'text/html')
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

  const warnings = []
  const open = await boardIds('open')
  const closed = await boardIds('closed')
  const ids = [...new Set([...open, ...closed])]
  const loads = []
  for (const id of ids) {
    try {
      const html = await (await fetch(`${D}?window_id=0&duplicate=0&id=${id}&dispatch_status=open&pending=0&office_id=0`, { credentials: 'include' })).text()
      const L = parseLoad(html, id)
      if (!L.meta.loadNum) { warnings.push(`editId ${id}: no load_number parsed (skipped)`); continue }
      if (!L.stops.some((s) => s.t === 'pu')) warnings.push(`load ${L.meta.loadNum}: no pickup stop`)
      if (!L.stops.some((s) => s.t === 'del')) warnings.push(`load ${L.meta.loadNum}: no delivery stop`)
      loads.push(L)
      await sleep(250) // be gentle on ITS
    } catch (e) { warnings.push(`editId ${id}: fetch/parse failed: ${String(e).slice(0, 80)}`) }
  }
  return { boards: { open: open.length, closed: closed.length }, loads, warnings }
}

// ── login ────────────────────────────────────────────────────────────────────
async function ensureLoggedIn(page) {
  await page.goto('https://app.itsdispatch.com/dispatch.php', { waitUntil: 'domcontentloaded' })
  if (/dispatch\.php/.test(page.url()) && !/login/.test(page.url())) {
    // Already authenticated (persistent profile). Confirm the board shell exists.
    const ok = await page.locator('text=DISPATCH BOARD').count().catch(() => 0)
    if (ok) return
  }
  // Fresh credential login.
  if (!env.ITS_PASSWORD || (!env.ITS_USERNAME && !env.ITS_EMAIL)) {
    throw new Error('ITS credentials missing in its.env (need ITS_PASSWORD and ITS_USERNAME or ITS_EMAIL)')
  }
  await page.goto('https://app.itsdispatch.com/login.php', { waitUntil: 'domcontentloaded' })
  if (env.ITS_ACCOUNT) await page.fill('#account_numberlgn', env.ITS_ACCOUNT).catch(() => {})
  if (env.ITS_USERNAME) await page.fill('#usernamelgn', env.ITS_USERNAME).catch(() => {})
  if (env.ITS_EMAIL) await page.fill('#email', env.ITS_EMAIL).catch(() => {})
  await page.fill('#password', env.ITS_PASSWORD)
  await page.check('#remember_login').catch(() => {})
  await Promise.all([
    page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 45000 }).catch(() => {}),
    page.click('#frmAppLogin button[type=submit], #frmAppLogin input[type=submit]').catch(() => page.press('#password', 'Enter')),
  ])
  await page.waitForTimeout(2500)
  if (/login\.php/.test(page.url())) {
    throw new Error(`ITS login failed — still on ${page.url()} (check credentials / account number)`)
  }
  log('logged in')
}

// ── accumulation ──────────────────────────────────────────────────────────────
function mergeAccumulate(fresh) {
  const byEdit = new Map()
  if (existsSync(ACCUM)) {
    try { for (const L of JSON.parse(readFileSync(ACCUM, 'utf8'))) byEdit.set(L.meta.editId, L) } catch { /* start fresh */ }
  }
  let added = 0, updated = 0
  for (const L of fresh) {
    const prev = byEdit.get(L.meta.editId)
    if (!prev) { byEdit.set(L.meta.editId, L); added++; continue }
    // Update if the load's material fields changed (status/rate/stops evolve until delivery).
    const sig = (x) => JSON.stringify([x.status, x.total_rate, x.total_miles, x.driver, x.truck, x.stops])
    if (sig(prev) !== sig(L)) { byEdit.set(L.meta.editId, L); updated++ }
  }
  const all = [...byEdit.values()]
  writeFileSync(ACCUM, JSON.stringify(all, null, 1))
  return { added, updated, total: all.length }
}

function selfcheck(loads, warnings) {
  const problems = []
  if (loads.length === 0) problems.push('no loads returned from the board')
  for (const L of loads) {
    if (!/^\d+$/.test(L.meta.editId)) problems.push(`load ${L.meta.loadNum}: bad editId`)
    if (!L.meta.loadNum) problems.push(`editId ${L.meta.editId}: no load number`)
    if (!(Number(L.total_rate) >= 0)) problems.push(`load ${L.meta.loadNum}: non-numeric rate "${L.total_rate}"`)
    if (!L.customer_name) problems.push(`load ${L.meta.loadNum}: no customer name`)
    const pu = L.stops.filter((s) => s.t === 'pu'), del = L.stops.filter((s) => s.t === 'del')
    if (!pu.length || !del.length) problems.push(`load ${L.meta.loadNum}: missing pickup or delivery`)
    for (const s of L.stops) if (s.date && !/^\d{4}-\d{2}-\d{2}$/.test(s.date)) problems.push(`load ${L.meta.loadNum}: bad stop date "${s.date}"`)
  }
  return problems
}

async function main() {
  mkdirSync(CAPTURE_DIR, { recursive: true })
  const ctx = await chromium.launchPersistentContext(PROFILE, { headless: !HEADED, acceptDownloads: false })
  const page = ctx.pages()[0] || await ctx.newPage()

  try {
    if (MODE_LOGIN) {
      log('login mode — a window is open; sign in to ITS, then press Enter here.')
      await page.goto('https://app.itsdispatch.com/login.php')
      await new Promise((r) => process.stdin.once('data', r))
      log('session saved to the persistent profile.')
      return
    }

    await ensureLoggedIn(page)
    log(`harvesting board (lookback ${LOOKBACK}d)…`)
    const { boards, loads, warnings } = await page.evaluate(harvest, LOOKBACK)
    log(`boards: open=${boards.open} closed=${boards.closed} → ${loads.length} loads parsed`)
    for (const w of warnings.slice(0, 30)) log(`  warn: ${w}`)

    const problems = selfcheck(loads, warnings)
    if (MODE_SELFCHECK) {
      if (problems.length) { problems.forEach((p) => log(`  FAIL: ${p}`)); throw new Error(`selfcheck failed: ${problems.length} problem(s)`) }
      log('selfcheck OK — every load has a number, customer, ≥1 pickup, ≥1 delivery, numeric rate, valid dates.')
      // Show one sample for eyeballing.
      log(`sample: ${JSON.stringify(loads[0], null, 1)}`)
      return
    }
    if (problems.length > loads.length * 0.25) { // tolerate a few; alarm on systemic breakage
      await alert('ITS capture: parser anomalies', problems.slice(0, 20).join('\n'))
    }

    // Always drop a timestamped raw snapshot (audit trail; never overwritten).
    const snap = join(CAPTURE_DIR, `${isoDate()}.json`)
    writeFileSync(snap, JSON.stringify({ capturedAt: new Date().toISOString(), boards, loads, warnings }, null, 1))
    log(`snapshot → ${snap}`)

    if (MODE_ONCE) { log('--once: snapshot only, accumulation skipped.'); return }
    const { added, updated, total } = mergeAccumulate(loads)
    log(`accumulated its_loads_full.json: +${added} new, ~${updated} updated, ${total} total captured`)
    log('done. NOTE: nothing was written to prod. Run import.mjs at cutover to load the delta.')
  } finally {
    await ctx.close()
  }
}

main().catch((e) => {
  console.error(`[its] ERROR: ${e.message}`)
  alert('ITS delta capture failed', e.message).finally(() => process.exit(1))
})

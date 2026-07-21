// Truxon watchdog v2 — cron-invoked (5 min) health checks over the Trux
// pipeline, the platform, AND the trucking business, with a tiered self-heal
// engine whose hands are enumerable in code (../_shared/remediations.ts).
//
// Checks:
//   inbox_poll_fresh    trux_inbox_state.last_poll advanced recently
//   inbox_failures      trux_inbox_log failures in the last hour
//   inbox_stuck         rows wedged mid-processing past a poll cycle
//   graph_auth          Graph token obtainable (catches expired client secret)
//   inbox_unread_stale  unread staff mail sitting > STALE_MIN in Inbox/Junk
//   edge:<fn>           each edge function answers (CORS preflight)
//   llm_provider        LLM API reachable with our key
//   gps_tracking        on-duty drivers are still reporting positions
//   backup_fresh        the NAS backup job pinged its heartbeat < 26h ago
//   invoice_integrity   no duplicate live invoice numbers; sequence not behind
//   frontend_up         truxon.com responds
//
// Self-heal ladder (see remediations.ts for the enforced boundary):
//   Tier 0/3  deterministic, reversible, rate-limited DB remediations run
//             automatically and are verified (reverted if the canary fails).
//   Tier 2    riskier-but-allowlisted actions wait for a one-tap approval
//             emailed to the owner (prefetch-safe: link → confirm page → POST).
//   Tier 1    LLM diagnosis stays in the READ-ONLY workstation responder;
//             code/schema/secret/data changes are proposal-only for a human.
//
// Modes (POST body):
//   {}                       run checks + self-heal (cron)
//   {report,key}             workstation responder emails a resolution through us
//   {heartbeat,key,detail?}  external job (NAS backup) records a heartbeat
//   {approve_token,confirm}  execute a previously-proposed remediation
// GET ?approve=<token>       prefetch-safe confirmation page for the email link

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { getCaller, json, requireCron } from '../_shared/auth.ts'
import { graph, graphConfigured, graphToken, sendMailAsTrux, TRUX_MAILBOX } from '../_shared/msgraph.ts'
import { type Remediation, remediationFor, type Svc } from '../_shared/remediations.ts'

const ALERT_TO = (Deno.env.get('WATCHDOG_ALERT_TO') ?? 'turkyildiz@gmail.com').split(',').map((s) => s.trim())
const PUBLIC_URL = Deno.env.get('WATCHDOG_PUBLIC_URL') ?? `${Deno.env.get('SUPABASE_URL')}/functions/v1/watchdog`
const STALE_MIN = 12
const COOLDOWN_MIN = 60
const GPS_STALE_MIN = 15
const EDGE_FNS = ['trux-agent', 'trux-inbox', 'extract-pdf', 'distance', 'admin-users', 'notify']

type CheckResult = { name: string; ok: boolean; detail: string; severity?: 'info' | 'warn' | 'critical' }

function svcClient(): Svc {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
}

const TRANSIENT = /429|tool_use_failed|timed? ?out|ECONN|fetch failed|network|50[0-9]:/i

function token(): string {
  return (crypto.randomUUID() + crypto.randomUUID()).replace(/-/g, '')
}

// ---------- legacy inbox retry playbook (unchanged) ----------
async function runPlaybooks(svc: Svc, tok: string): Promise<string[]> {
  const actions: string[] = []
  const cutoff = new Date(Date.now() - 8 * 60000).toISOString()
  const { data: failed } = await svc.from('trux_inbox_log')
    .select('graph_message_id, detail, retries')
    .eq('status', 'failed').lt('created_at', cutoff).lt('retries', 2).limit(5)
  for (const f of failed ?? []) {
    if (!TRANSIENT.test(f.detail ?? '')) continue
    const r = await graph(tok, `/users/${encodeURIComponent(TRUX_MAILBOX)}/messages/${f.graph_message_id}`, {
      method: 'PATCH', body: JSON.stringify({ isRead: false }),
    })
    if (r.ok) {
      await svc.from('trux_inbox_log')
        .update({ status: 'retry_pending', retries: (f.retries ?? 0) + 1 })
        .eq('graph_message_id', f.graph_message_id)
      actions.push(`retry scheduled for message ${f.graph_message_id.slice(-12)} (attempt ${(f.retries ?? 0) + 1})`)
    }
  }
  return actions
}

async function runChecks(svc: Svc): Promise<CheckResult[]> {
  const results: CheckResult[] = []
  const base = Deno.env.get('SUPABASE_URL')

  // --- inbox poll freshness ---
  try {
    const { data } = await svc.from('trux_inbox_state').select('last_poll').eq('id', 1).single()
    const age = (Date.now() - new Date(data!.last_poll as string).getTime()) / 60000
    // A future last_poll (age < 0) is the wedged-throttle failure the reset
    // remediation fixes — it must read as failing, not as "fresh".
    results.push({
      name: 'inbox_poll_fresh',
      ok: age >= 0 && age < 6,
      detail: age < 0 ? `last poll ${(-age).toFixed(1)} min in the FUTURE (throttle stuck)` : `last poll ${age.toFixed(1)} min ago`,
    })
  } catch (e) {
    results.push({ name: 'inbox_poll_fresh', ok: false, detail: `query failed: ${e instanceof Error ? e.message : e}` })
  }

  // --- recent processing failures ---
  try {
    const oneHourAgo = new Date(Date.now() - 3600_000).toISOString()
    const { count } = await svc.from('trux_inbox_log')
      .select('id', { count: 'exact', head: true }).eq('status', 'failed').gte('created_at', oneHourAgo)
    results.push({ name: 'inbox_failures', ok: (count ?? 0) === 0, detail: `${count ?? 0} failed in last hour` })
  } catch (e) {
    results.push({ name: 'inbox_failures', ok: false, detail: `query failed: ${e instanceof Error ? e.message : e}` })
  }

  // --- DB-heavy business probes (one round trip) ---
  try {
    const { data: p, error } = await svc.rpc('watchdog_db_probes', { p_gps_stale_min: GPS_STALE_MIN })
    if (error) throw new Error(error.message)
    results.push({
      name: 'inbox_stuck',
      ok: (p.stuck_processing ?? 0) === 0,
      detail: `${p.stuck_processing ?? 0} message(s) stuck processing`,
    })
    results.push({
      name: 'gps_tracking',
      ok: (p.gps_stale ?? 0) === 0,
      detail: `${p.gps_stale ?? 0}/${p.gps_on_duty ?? 0} on-duty drivers not reporting (> ${GPS_STALE_MIN} min)`,
      severity: 'critical',
    })
    results.push({
      name: 'invoice_integrity',
      ok: (p.invoice_dupes ?? 0) === 0 && p.invoice_seq_behind !== true,
      detail: p.invoice_dupes ? `${p.invoice_dupes} duplicate live invoice number(s)`
        : p.invoice_seq_behind ? 'invoice sequence is behind the max issued number' : 'ok',
      severity: 'critical',
    })
    results.push({
      name: 'backup_fresh',
      ok: p.backup_stale !== true,
      detail: p.backup_last_seen ? `last backup heartbeat ${p.backup_last_seen}` : 'no backup heartbeat recorded',
      severity: 'critical',
    })
  } catch (e) {
    results.push({ name: 'db_probes', ok: false, detail: `probe RPC failed: ${e instanceof Error ? e.message : e}` })
  }

  // --- Graph auth + stale unread mail ---
  if (graphConfigured()) {
    let tok = ''
    try {
      tok = await graphToken()
      results.push({ name: 'graph_auth', ok: true, detail: 'token ok' })
    } catch (e) {
      results.push({ name: 'graph_auth', ok: false, detail: e instanceof Error ? e.message : String(e) })
    }
    if (tok) {
      try {
        const cutoff = new Date(Date.now() - STALE_MIN * 60000).toISOString()
        let stale = 0
        for (const folder of ['Inbox', 'JunkEmail']) {
          const r = await graph(tok, `/users/${encodeURIComponent(TRUX_MAILBOX)}/mailFolders/${folder}/messages?$filter=isRead eq false and receivedDateTime lt ${cutoff}&$top=10&$select=id`)
          if (r.ok) stale += (((await r.json()).value ?? []) as unknown[]).length
        }
        results.push({ name: 'inbox_unread_stale', ok: stale === 0, detail: `${stale} unread > ${STALE_MIN} min` })
      } catch (e) {
        results.push({ name: 'inbox_unread_stale', ok: false, detail: e instanceof Error ? e.message : String(e) })
      }
    }
  }

  // --- edge functions alive (CORS preflight needs no auth) ---
  for (const fn of EDGE_FNS) {
    try {
      const r = await fetch(`${base}/functions/v1/${fn}`, {
        method: 'OPTIONS',
        headers: { Origin: 'https://truxon.com', 'Access-Control-Request-Method': 'POST' },
      })
      results.push({ name: `edge:${fn}`, ok: r.status < 500, detail: `status ${r.status}` })
    } catch (e) {
      results.push({ name: `edge:${fn}`, ok: false, detail: e instanceof Error ? e.message : String(e) })
    }
  }

  // --- Trux's active LLM provider reachable ---
  try {
    const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY')
    if (anthropicKey) {
      const r = await fetch('https://api.anthropic.com/v1/models', {
        headers: { 'x-api-key': anthropicKey, 'anthropic-version': '2023-06-01' },
      })
      results.push({ name: 'llm_provider', ok: r.ok, detail: `anthropic status ${r.status}` })
    } else {
      const key = Deno.env.get('LLM_API_KEY')
      const baseUrl = Deno.env.get('LLM_BASE_URL') ?? 'https://api.groq.com/openai/v1'
      if (!key) results.push({ name: 'llm_provider', ok: false, detail: 'no LLM key set' })
      else {
        const r = await fetch(`${baseUrl.replace(/\/$/, '')}/models`, { headers: { Authorization: `Bearer ${key}` } })
        results.push({ name: 'llm_provider', ok: r.ok, detail: `groq status ${r.status}` })
      }
    }
  } catch (e) {
    results.push({ name: 'llm_provider', ok: false, detail: e instanceof Error ? e.message : String(e) })
  }

  // --- frontend reachable ---
  try {
    const r = await fetch('https://truxon.com', { method: 'HEAD', signal: AbortSignal.timeout(10000) })
    results.push({ name: 'frontend_up', ok: r.status < 500, detail: `truxon.com status ${r.status}` })
  } catch (e) {
    results.push({ name: 'frontend_up', ok: false, detail: `unreachable: ${e instanceof Error ? e.message : e}` })
  }

  return results
}

// ---------- incidents ----------
async function openIncident(svc: Svc, r: CheckResult): Promise<number | null> {
  const { data: existing } = await svc.from('watchdog_incidents')
    .select('id').eq('check_name', r.name).eq('status', 'open').maybeSingle()
  if (existing) {
    await svc.from('watchdog_incidents').update({ detail: r.detail, updated_at: new Date().toISOString() }).eq('id', existing.id)
    return existing.id
  }
  const { data: created } = await svc.from('watchdog_incidents')
    .insert({ check_name: r.name, severity: r.severity ?? 'warn', detail: r.detail })
    .select('id').single()
  return created?.id ?? null
}

async function resolveIncident(svc: Svc, checkName: string): Promise<void> {
  await svc.from('watchdog_incidents')
    .update({ status: 'resolved', resolved_at: new Date().toISOString(), updated_at: new Date().toISOString() })
    .eq('check_name', checkName).eq('status', 'open')
}

// ---------- self-heal engine ----------
type HealNote = { line: string; approval?: { token: string; describe: string } }

async function underRateLimit(svc: Svc, rem: Remediation): Promise<boolean> {
  const { data } = await svc.rpc('watchdog_action_count', { p_action_key: rem.key, p_since_minutes: 60 })
  return (data ?? 0) < rem.maxPerHour
}

/** Snapshot → apply → verify → (revert on canary fail). Ledgered throughout. */
async function applyRemediation(svc: Svc, rem: Remediation, incidentId: number | null, tier: 'auto' | 'approval', existingRowId?: number): Promise<string> {
  const before = await rem.snapshot(svc)
  const baseRow = {
    incident_id: incidentId, check_name: rem.key, action_key: rem.key, tier,
    before_state: before, status: 'applied', params: {},
  }
  let rowId = existingRowId
  if (rowId) {
    await svc.from('watchdog_remediations').update({ status: 'applied', before_state: before, decided_at: new Date().toISOString() }).eq('id', rowId)
  } else {
    const { data, error } = await svc.from('watchdog_remediations').insert(baseRow).select('id').single()
    if (error) return `✗ ${rem.key}: could not open ledger row — ${error.message}`
    rowId = data?.id
  }
  try {
    const detail = await rem.apply(svc, before)
    const ok = await rem.verify(svc)
    if (ok) {
      await svc.from('watchdog_remediations').update({ status: 'verified', after_state: await rem.snapshot(svc), detail }).eq('id', rowId)
      return `✓ ${rem.key}: ${detail} (verified)`
    }
    await rem.revert(svc, before)
    await svc.from('watchdog_remediations').update({ status: 'reverted', detail: `${detail}; canary failed, reverted` }).eq('id', rowId)
    return `↺ ${rem.key}: applied but canary failed — reverted`
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    try { await rem.revert(svc, before) } catch { /* best effort */ }
    await svc.from('watchdog_remediations').update({ status: 'failed', detail: msg }).eq('id', rowId)
    return `✗ ${rem.key}: failed — ${msg}`
  }
}

async function runSelfHeal(svc: Svc, failing: CheckResult[], incidentIds: Map<string, number | null>): Promise<HealNote[]> {
  const notes: HealNote[] = []
  for (const r of failing) {
    const rem = remediationFor(r.name, r.detail)
    if (!rem) continue
    if (!(await underRateLimit(svc, rem))) {
      notes.push({ line: `⚠ ${rem.key}: rate limit reached (${rem.maxPerHour}/h) — not retried automatically` })
      continue
    }
    const incidentId = incidentIds.get(r.name) ?? null
    if (rem.tier === 'auto') {
      notes.push({ line: await applyRemediation(svc, rem, incidentId, 'auto') })
    } else {
      // Only one live proposal per action at a time.
      const { data: pending } = await svc.from('watchdog_remediations')
        .select('id').eq('action_key', rem.key).eq('status', 'proposed')
        .gt('expires_at', new Date().toISOString()).maybeSingle()
      if (pending) { notes.push({ line: `… ${rem.key}: awaiting your approval` }); continue }
      const tok = token()
      const { error: insErr } = await svc.from('watchdog_remediations').insert({
        incident_id: incidentId, check_name: r.name, action_key: rem.key, tier: 'approval',
        status: 'proposed', approval_token: tok,
        expires_at: new Date(Date.now() + 24 * 3600_000).toISOString(),
        detail: rem.describe(r.name, r.detail),
      })
      if (insErr) { notes.push({ line: `✗ ${rem.key}: could not record proposal — ${insErr.message}` }); continue }
      notes.push({ line: `🔒 ${rem.key}: proposed (needs approval)`, approval: { token: tok, describe: rem.describe(r.name, r.detail) } })
    }
  }
  return notes
}

/** Execute a previously-proposed remediation after a one-tap approval. */
async function executeApproved(svc: Svc, tok: string): Promise<{ ok: boolean; message: string }> {
  const { data: row } = await svc.from('watchdog_remediations')
    .select('*').eq('approval_token', tok).eq('status', 'proposed').maybeSingle()
  if (!row) return { ok: false, message: 'This approval is invalid or already used.' }
  if (row.expires_at && new Date(row.expires_at).getTime() < Date.now()) {
    await svc.from('watchdog_remediations').update({ status: 'expired' }).eq('id', row.id)
    return { ok: false, message: 'This approval has expired.' }
  }
  const rem = remediationFor(row.check_name, row.detail)
  if (!rem || rem.key !== row.action_key) {
    return { ok: false, message: 'The proposed action is no longer available.' }
  }
  const result = await applyRemediation(svc, rem, row.incident_id, 'approval', row.id)
  return { ok: true, message: result }
}

// ---------- alerting ----------
async function pushAdmins(svc: Svc, title: string, body: string): Promise<void> {
  try {
    const { data: admins } = await svc.from('profiles').select('id').eq('role', 'admin').eq('is_active', true)
    const url = `${Deno.env.get('SUPABASE_URL')}/functions/v1/notify`
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    for (const a of admins ?? []) {
      await fetch(url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'send', user_id: a.id, title, body: body.slice(0, 240), urgent: true }),
      }).catch(() => {})
    }
  } catch { /* push is best-effort */ }
}

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!))

function approvalPage(tok: string, describe: string): Response {
  // Prefetch-safe: the emailed GET renders this page; nothing executes until
  // the human presses Confirm, which POSTs. Mail scanners fetching the link
  // therefore cannot trigger the action.
  const html = `<!doctype html><meta name="robots" content="noindex"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:16px system-ui;margin:0;background:#0f172a;color:#e2e8f0;display:grid;place-items:center;height:100vh}
.c{max-width:32rem;padding:2rem;background:#1e293b;border-radius:1rem;text-align:center}
button{font:600 16px system-ui;padding:.75rem 1.5rem;border:0;border-radius:.75rem;background:#2563eb;color:#fff;cursor:pointer}
.d{margin:1rem 0;padding:1rem;background:#0f172a;border-radius:.5rem}</style>
<div class="c"><h2>Approve Trux remediation?</h2><div class="d">${escapeHtml(describe)}</div>
<form method="POST"><input type="hidden" name="approve_token" value="${escapeHtml(tok)}"><input type="hidden" name="confirm" value="1">
<button type="submit">Confirm &amp; apply</button></form><p style="color:#94a3b8;font-size:13px">This link is single-use and expires in 24h.</p></div>`
  return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8' } })
}

Deno.serve(async (req) => {
  const url = new URL(req.url)

  // Prefetch-safe approval link (GET renders confirm page).
  if (req.method === 'GET' && url.searchParams.get('approve')) {
    const svc = svcClient()
    const tok = url.searchParams.get('approve')!
    const { data: row } = await svc.from('watchdog_remediations')
      .select('detail, status').eq('approval_token', tok).maybeSingle()
    if (!row || row.status !== 'proposed') {
      return new Response('<!doctype html><p style="font:16px system-ui;padding:2rem">This approval is invalid, already used, or expired.</p>',
        { headers: { 'Content-Type': 'text/html; charset=utf-8' } })
    }
    return approvalPage(tok, row.detail)
  }
  if (req.method !== 'POST' && req.method !== 'GET') return json({ error: 'Method not allowed' }, 405)

  // POST bodies arrive as JSON (cron/report/heartbeat) or form (approval confirm).
  let body: Record<string, unknown> = {}
  if (req.method === 'POST') {
    const ct = req.headers.get('content-type') ?? ''
    if (ct.includes('application/x-www-form-urlencoded')) {
      const form = await req.formData()
      body = Object.fromEntries([...form.entries()].map(([k, v]) => [k, String(v)]))
    } else {
      body = await req.json().catch(() => ({}))
    }
  }

  const svc = svcClient()

  // --- one-time setter: store the DB-side cron secret (admin session only) ---
  if (body.set_cron_secret) {
    const caller = await getCaller(req)
    if (caller instanceof Response) return caller
    if (caller.role !== 'admin') return json({ error: 'Admin only' }, 403)
    const { error } = await svc.rpc('set_cron_config', { p_key: 'cron_secret', p_value: String(body.set_cron_secret) })
    if (error) return json({ error: error.message }, 400)
    return json({ ok: true })
  }

  // --- approval execution ---
  if (body.approve_token && body.confirm) {
    const res = await executeApproved(svc, String(body.approve_token))
    const msg = escapeHtml(res.message)
    return new Response(`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><div style="font:16px system-ui;max-width:32rem;margin:3rem auto;padding:0 1rem;text-align:center"><h2>${res.ok ? '✓ Done' : '⚠ Not applied'}</h2><p>${msg}</p></div>`,
      { headers: { 'Content-Type': 'text/html; charset=utf-8' } })
  }

  // --- report mode (workstation responder emails a resolution through us) ---
  if (body.report) {
    const expected = Deno.env.get('WATCHDOG_REPORT_KEY')
    if (!expected || body.key !== expected) return json({ error: 'Forbidden' }, 403)
    try {
      const tok = await graphToken()
      const report = body.report as { subject?: string; body?: string }
      const sent = await sendMailAsTrux(tok, ALERT_TO, `[Trux responder] ${String(report.subject ?? 'report')}`.slice(0, 150), String(report.body ?? '').slice(0, 8000))
      return json({ sent })
    } catch (e) {
      return json({ error: e instanceof Error ? e.message : String(e) }, 502)
    }
  }

  // --- heartbeat mode (NAS backup job etc.) ---
  if (body.heartbeat) {
    const expected = Deno.env.get('WATCHDOG_REPORT_KEY')
    if (!expected || body.key !== expected) return json({ error: 'Forbidden' }, 403)
    await svc.from('watchdog_heartbeats').upsert({
      source: String(body.heartbeat), last_seen: new Date().toISOString(), detail: String(body.detail ?? ''),
    })
    return json({ recorded: String(body.heartbeat) })
  }

  // --- default: run checks + self-heal --- (S-05: cron-only door)
  if (!requireCron(req)) return json({ error: 'Not authorized' }, 401)
  let playbook: string[] = []
  if (graphConfigured()) {
    try { playbook = await runPlaybooks(svc, await graphToken()) } catch { /* never break checks */ }
  }

  const results = await runChecks(svc)
  const now = new Date().toISOString()

  const transitions: { name: string; from: string; to: string; detail: string }[] = []
  const needAlert: CheckResult[] = []
  const stateful: (CheckResult & { last_change: string })[] = []
  const incidentIds = new Map<string, number | null>()

  for (const r of results) {
    const { data: prev } = await svc.from('watchdog_state').select('*').eq('check_name', r.name).maybeSingle()
    const newStatus = r.ok ? 'ok' : 'fail'
    const changed = !prev || prev.status !== newStatus
    if (changed && prev) transitions.push({ name: r.name, from: prev.status, to: newStatus, detail: r.detail })

    if (!r.ok) incidentIds.set(r.name, await openIncident(svc, r))
    else if (changed) await resolveIncident(svc, r.name)

    const cooldownOver = !prev?.last_alert || Date.now() - new Date(prev.last_alert).getTime() > COOLDOWN_MIN * 60000
    const alertNow = !r.ok && (changed || cooldownOver)
    if (alertNow) needAlert.push(r)

    const lastChange = changed ? now : prev?.last_change ?? now
    stateful.push({ ...r, last_change: lastChange })
    await svc.from('watchdog_state').upsert({
      check_name: r.name, status: newStatus, detail: r.detail, last_change: lastChange,
      last_alert: alertNow ? now : prev?.last_alert ?? null, updated_at: now,
    })
  }

  // Self-heal every currently-failing check (idempotent; rate-limited).
  const failing = results.filter((r) => !r.ok)
  const heal = failing.length ? await runSelfHeal(svc, failing, incidentIds) : []

  const recoveries = transitions.filter((t) => t.to === 'ok')
  let alerted = false
  if ((needAlert.length || recoveries.length || heal.some((h) => h.approval)) && graphConfigured()) {
    try {
      const tok = await graphToken()
      const lines: string[] = []
      if (needAlert.length) { lines.push('FAILING CHECKS:'); for (const r of needAlert) lines.push(`  ✗ ${r.name} — ${r.detail}`) }
      if (recoveries.length) { lines.push('', 'RECOVERED:'); for (const t of recoveries) lines.push(`  ✓ ${t.name} — ${t.detail}`) }
      if (heal.length) {
        lines.push('', 'SELF-HEAL:')
        for (const h of heal) {
          lines.push(`  ${h.line}`)
          if (h.approval) lines.push(`     approve: ${PUBLIC_URL}?approve=${h.approval.token}`)
        }
      }
      if (playbook.length) { lines.push('', 'INBOX RETRIES:'); for (const p of playbook) lines.push(`  ⟳ ${p}`) }
      lines.push('', `All checks: ${results.filter((r) => r.ok).length}/${results.length} ok`, `Time: ${now}`, '', '— Forest watchdog')
      const subject = needAlert.length
        ? `⚠ Truxon watchdog: ${needAlert.length} check${needAlert.length > 1 ? 's' : ''} failing`
        : heal.some((h) => h.approval) ? '🔒 Truxon watchdog: action needs your approval'
        : '✓ Truxon watchdog: recovered'
      alerted = await sendMailAsTrux(tok, ALERT_TO, subject, lines.join('\n'))
    } catch { /* alerting must never break the watchdog */ }
  }
  if (needAlert.length) {
    await pushAdmins(svc, `⚠ Truxon: ${needAlert.length} check(s) failing`, needAlert.map((r) => `${r.name}: ${r.detail}`).join('; '))
  }

  // Context for the read-only workstation responder (no privileged creds needed).
  let recentFailures: unknown[] = []
  if (failing.length) {
    const { data } = await svc.from('trux_inbox_log')
      .select('created_at, subject, status, detail, retries').in('status', ['failed', 'retry_pending'])
      .order('id', { ascending: false }).limit(5)
    recentFailures = data ?? []
  }

  return json({
    ok: results.every((r) => r.ok),
    checks: stateful,
    transitions,
    self_heal: heal.map((h) => h.line),
    playbook,
    recent_failures: recentFailures,
    alerted,
  })
})

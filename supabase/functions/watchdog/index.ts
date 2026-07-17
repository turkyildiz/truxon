// Truxon watchdog — cron-invoked (5 min) health checks over the Trux
// pipeline and platform. Records state transitions in watchdog_state and
// emails alerts FROM the Trux mailbox on failure/recovery, with a 60-min
// re-alert cooldown for persistent failures.
//
// Checks:
//   inbox_unread_stale  unread staff mail sitting > STALE_MIN in Inbox/Junk
//   inbox_failures      trux_inbox_log failures in the last hour
//   inbox_poll_fresh    trux_inbox_state.last_poll advanced recently
//   edge:<fn>           each edge function answers (CORS preflight)
//   llm_provider        LLM API reachable with our key
//   graph_auth          Graph token obtainable (catches expired client secret)

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { json } from '../_shared/auth.ts'
import { graph, graphConfigured, graphToken, sendMailAsTrux, TRUX_MAILBOX } from '../_shared/msgraph.ts'

const ALERT_TO = (Deno.env.get('WATCHDOG_ALERT_TO') ?? 'turkyildiz@gmail.com').split(',').map((s) => s.trim())
const STALE_MIN = 12
const COOLDOWN_MIN = 60
const EDGE_FNS = ['trux-agent', 'trux-inbox', 'extract-pdf', 'distance', 'admin-users', 'notify']

type CheckResult = { name: string; ok: boolean; detail: string }

function svcClient() {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
}

/** Signatures of failures that clear themselves given another attempt. */
const TRANSIENT = /429|tool_use_failed|timed? ?out|ECONN|fetch failed|network|50[0-9]:/i

/** Playbook: schedule automatic retry of transient inbox failures — mark the
 * Graph message unread and flip the log row to retry_pending; the poller
 * reclaims it on its next sweep. Max 2 retries per message, and only after
 * the rate-limit window has had time to clear. */
async function runPlaybooks(svc: ReturnType<typeof svcClient>, tok: string): Promise<string[]> {
  const actions: string[] = []
  const cutoff = new Date(Date.now() - 8 * 60000).toISOString()
  const { data: failed } = await svc.from('trux_inbox_log')
    .select('graph_message_id, detail, retries')
    .eq('status', 'failed')
    .lt('created_at', cutoff)
    .lt('retries', 2)
    .limit(5)
  for (const f of failed ?? []) {
    if (!TRANSIENT.test(f.detail ?? '')) continue
    const r = await graph(tok, `/users/${encodeURIComponent(TRUX_MAILBOX)}/messages/${f.graph_message_id}`, {
      method: 'PATCH',
      body: JSON.stringify({ isRead: false }),
    })
    if (r.ok) {
      await svc.from('trux_inbox_log')
        .update({ status: 'retry_pending', retries: (f.retries ?? 0) + 1 })
        .eq('graph_message_id', f.graph_message_id)
      actions.push(`retry scheduled for message ${f.graph_message_id.slice(-12)} (attempt ${(f.retries ?? 0) + 1})`)
    } else {
      actions.push(`retry mark-unread failed (${r.status}) for ${f.graph_message_id.slice(-12)}`)
    }
  }
  return actions
}

async function runChecks(svc: ReturnType<typeof svcClient>): Promise<CheckResult[]> {
  const results: CheckResult[] = []

  // --- inbox poll freshness ---
  try {
    const { data } = await svc.from('trux_inbox_state').select('last_poll').eq('id', 1).single()
    const age = (Date.now() - new Date(data!.last_poll as string).getTime()) / 60000
    results.push({ name: 'inbox_poll_fresh', ok: age < 6, detail: `last poll ${age.toFixed(1)} min ago` })
  } catch (e) {
    results.push({ name: 'inbox_poll_fresh', ok: false, detail: `query failed: ${e instanceof Error ? e.message : e}` })
  }

  // --- recent processing failures ---
  try {
    const oneHourAgo = new Date(Date.now() - 3600_000).toISOString()
    const { count } = await svc.from('trux_inbox_log')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'failed')
      .gte('created_at', oneHourAgo)
    results.push({ name: 'inbox_failures', ok: (count ?? 0) === 0, detail: `${count ?? 0} failed in last hour` })
  } catch (e) {
    results.push({ name: 'inbox_failures', ok: false, detail: `query failed: ${e instanceof Error ? e.message : e}` })
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
          const r = await graph(
            tok,
            `/users/${encodeURIComponent(TRUX_MAILBOX)}/mailFolders/${folder}/messages?$filter=isRead eq false and receivedDateTime lt ${cutoff}&$top=10&$select=id`,
          )
          if (r.ok) stale += (((await r.json()).value ?? []) as unknown[]).length
        }
        results.push({ name: 'inbox_unread_stale', ok: stale === 0, detail: `${stale} unread > ${STALE_MIN} min` })
      } catch (e) {
        results.push({ name: 'inbox_unread_stale', ok: false, detail: e instanceof Error ? e.message : String(e) })
      }
    }
  }

  // --- edge functions alive (CORS preflight needs no auth) ---
  const base = Deno.env.get('SUPABASE_URL')
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

  // --- LLM provider reachable ---
  try {
    const key = Deno.env.get('LLM_API_KEY')
    const baseUrl = Deno.env.get('LLM_BASE_URL') ?? 'https://api.groq.com/openai/v1'
    if (!key) {
      results.push({ name: 'llm_provider', ok: false, detail: 'LLM_API_KEY not set' })
    } else {
      const r = await fetch(`${baseUrl.replace(/\/$/, '')}/models`, { headers: { Authorization: `Bearer ${key}` } })
      results.push({ name: 'llm_provider', ok: r.ok, detail: `status ${r.status}` })
    }
  } catch (e) {
    results.push({ name: 'llm_provider', ok: false, detail: e instanceof Error ? e.message : String(e) })
  }

  return results
}

Deno.serve(async (req) => {
  if (req.method !== 'POST' && req.method !== 'GET') return json({ error: 'Method not allowed' }, 405)
  const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {}

  // Report mode: the workstation responder emails its resolution through us.
  // Fixed recipients only; gated by a shared key.
  if (body.report) {
    const expected = Deno.env.get('WATCHDOG_REPORT_KEY')
    if (!expected || body.key !== expected) return json({ error: 'Forbidden' }, 403)
    try {
      const tok = await graphToken()
      const sent = await sendMailAsTrux(
        tok,
        ALERT_TO,
        `[Trux responder] ${String(body.report.subject ?? 'report')}`.slice(0, 150),
        String(body.report.body ?? '').slice(0, 8000),
      )
      return json({ sent })
    } catch (e) {
      return json({ error: e instanceof Error ? e.message : String(e) }, 502)
    }
  }

  const svc = svcClient()

  // Playbooks first — they may clear failures before we alert on them.
  let playbook: string[] = []
  if (graphConfigured()) {
    try {
      playbook = await runPlaybooks(svc, await graphToken())
    } catch { /* playbooks must never break the checks */ }
  }

  const results = await runChecks(svc)
  const now = new Date().toISOString()

  const transitions: { name: string; from: string; to: string; detail: string }[] = []
  const needAlert: CheckResult[] = []
  const stateful: (CheckResult & { last_change: string })[] = []

  for (const r of results) {
    const { data: prev } = await svc.from('watchdog_state').select('*').eq('check_name', r.name).maybeSingle()
    const newStatus = r.ok ? 'ok' : 'fail'
    const changed = !prev || prev.status !== newStatus
    if (changed && prev) transitions.push({ name: r.name, from: prev.status, to: newStatus, detail: r.detail })

    const cooldownOver = !prev?.last_alert || Date.now() - new Date(prev.last_alert).getTime() > COOLDOWN_MIN * 60000
    const alertNow = !r.ok && (changed || cooldownOver)
    if (alertNow) needAlert.push(r)

    const lastChange = changed ? now : prev?.last_change ?? now
    stateful.push({ ...r, last_change: lastChange })

    await svc.from('watchdog_state').upsert({
      check_name: r.name,
      status: newStatus,
      detail: r.detail,
      last_change: lastChange,
      last_alert: alertNow ? now : prev?.last_alert ?? null,
      updated_at: now,
    })
  }

  // Context for the workstation responder: recent failure detail without
  // needing any privileged credentials on its side.
  let recentFailures: unknown[] = []
  if (results.some((r) => !r.ok)) {
    const { data } = await svc.from('trux_inbox_log')
      .select('created_at, subject, status, detail, retries')
      .in('status', ['failed', 'retry_pending'])
      .order('id', { ascending: false })
      .limit(5)
    recentFailures = data ?? []
  }

  const recoveries = transitions.filter((t) => t.to === 'ok')
  let alerted = false
  if ((needAlert.length || recoveries.length) && graphConfigured()) {
    try {
      const tok = await graphToken()
      const lines: string[] = []
      if (needAlert.length) {
        lines.push('FAILING CHECKS:')
        for (const r of needAlert) lines.push(`  ✗ ${r.name} — ${r.detail}`)
      }
      if (recoveries.length) {
        lines.push('', 'RECOVERED:')
        for (const t of recoveries) lines.push(`  ✓ ${t.name} — ${t.detail}`)
      }
      if (playbook.length) {
        lines.push('', 'AUTO-REMEDIATION:')
        for (const p of playbook) lines.push(`  ⟳ ${p}`)
      }
      lines.push('', `All checks: ${results.filter((r) => r.ok).length}/${results.length} ok`, `Time: ${now}`, '', '— Trux watchdog')
      const subject = needAlert.length
        ? `⚠ Truxon watchdog: ${needAlert.length} check${needAlert.length > 1 ? 's' : ''} failing`
        : '✓ Truxon watchdog: recovered'
      alerted = await sendMailAsTrux(tok, ALERT_TO, subject, lines.join('\n'))
    } catch { /* alerting must never break the watchdog */ }
  }

  return json({
    ok: results.every((r) => r.ok),
    checks: stateful,
    transitions,
    playbook,
    recent_failures: recentFailures,
    alerted,
  })
})

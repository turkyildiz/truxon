// R9 #175: weekly report emailer. The Monday-07:00 cron posts here; we pull
// the due scheduled reports (rendered server-side), format each as a plain
// text digest, and email it via the shared Trux mailbox. Cron-gated only —
// there is no interactive caller. Best-effort per report: one failing send
// does not block the others, and only reports that actually send are stamped.
import { createClient } from 'jsr:@supabase/supabase-js@2'
import { json, requireCron, withCors } from '../_shared/auth.ts'
import { graphConfigured, graphToken, sendMailAsTrux } from '../_shared/msgraph.ts'

interface Row { metric_key: string; value: number | null; captured_on: string | null; prior: number | null }
interface Due { id: number; name: string; recipients: string[]; report: { rows: Row[]; as_of: string } }

function formatReport(d: Due): string {
  const lines = [`${d.name}`, `As of ${new Date(d.report.as_of).toLocaleDateString()}`, '']
  for (const r of d.report.rows) {
    const val = r.value == null ? '—' : Number(r.value).toLocaleString()
    let delta = ''
    if (r.value != null && r.prior != null && r.prior !== 0) {
      const pct = ((r.value - r.prior) / Math.abs(r.prior)) * 100
      delta = `  (${pct >= 0 ? '+' : ''}${pct.toFixed(1)}% WoW)`
    }
    lines.push(`${r.metric_key}: ${val}${delta}`)
  }
  lines.push('', '— Truxon scheduled report. Values from the nightly metric trend store.')
  return lines.join('\n')
}

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return json({ ok: true })
  if (!requireCron(req)) return json({ error: 'cron only' }, 403)
  if (!graphConfigured()) return json({ error: 'mail not configured', sent: 0 }, 200)

  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: due } = await svc.rpc('due_scheduled_reports')
  const reports = (due ?? []) as Due[]
  if (reports.length === 0) return json({ ok: true, sent: 0 })

  const tok = await graphToken()
  let sent = 0
  const failures: string[] = []
  for (const d of reports) {
    try {
      const ok = await sendMailAsTrux(tok, d.recipients, `Truxon report: ${d.name}`, formatReport(d))
      if (ok) { await svc.rpc('mark_report_sent', { p_id: d.id }); sent++ }
      else failures.push(d.name)
    } catch {
      failures.push(d.name)
    }
  }
  return json({ ok: true, sent, failures })
}))

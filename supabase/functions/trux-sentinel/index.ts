// Trux Sentinel runner — the proactive "comes to you" layer. pg_cron hits this:
//   mode 'scan'  (frequent) → run sentinel_scan(), then push each NEW critical
//                             insight to the owner exactly once.
//   mode 'brief' (daily)    → run the scan, then push a one-shot digest of
//                             everything still open.
// Stays behind the platform JWT gate (cron sends the public anon key, like
// trux-inbox); the real work uses the service role in-function. Pushing reuses
// the notify function.
import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { json } from '../_shared/auth.ts'

function svc(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
}

async function pushAdmins(s: SupabaseClient, title: string, body: string, urgent: boolean): Promise<number> {
  const { data: admins } = await s.from('profiles').select('id').eq('role', 'admin').eq('is_active', true)
  const url = Deno.env.get('SUPABASE_URL')!
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  let n = 0
  for (const a of (admins ?? []) as { id: string }[]) {
    await fetch(`${url}/functions/v1/notify`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'send', user_id: a.id, title: title.slice(0, 120), body: body.slice(0, 400), urgent }),
    }).catch(() => {})
    n++
  }
  return n
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const s = svc()

  let mode = 'scan'
  try {
    const b = await req.json()
    if (b?.mode) mode = String(b.mode)
  } catch { /* default scan */ }

  // Always refresh state first.
  const { data: scan, error: scanErr } = await s.rpc('sentinel_scan')
  if (scanErr) return json({ error: scanErr.message }, 500)

  if (mode === 'brief') {
    const { data: sum } = await s.rpc('sentinel_open_summary') as { data: { open?: number; critical?: number; top?: { severity: string; title: string }[] } | null }
    const openN = sum?.open ?? 0
    if (openN > 0) {
      const lines = (sum?.top ?? []).slice(0, 5).map((t) => `${t.severity === 'critical' ? '‼️' : '⚠️'} ${t.title}`).join('\n')
      await pushAdmins(s, `Trux daily brief — ${openN} open (${sum?.critical ?? 0} critical)`, lines || 'See the Trux feed.', false)
    }
    return json({ mode, summary: sum })
  }

  // scan mode: push each new critical exactly once.
  const { data: alerts } = await s.rpc('sentinel_take_alerts') as { data: { title: string; detail: string }[] | null }
  for (const a of alerts ?? []) {
    await pushAdmins(s, `‼️ ${a.title}`, a.detail, true)
  }
  return json({ mode, scan, pushed: (alerts ?? []).length })
})

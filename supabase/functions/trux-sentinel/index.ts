// Trux Sentinel runner — the proactive "comes to you" layer. pg_cron hits this:
//   mode 'scan'  (frequent) → run sentinel_scan(), then push each NEW critical
//                             insight to the owner exactly once.
//   mode 'brief' (daily)    → run the scan, then push a one-shot digest of
//                             everything still open.
// Stays behind the platform JWT gate (cron sends the public anon key, like
// trux-inbox). The DB's sentinel/maintenance RPCs gate on my_role()='admin', and
// after the API-key rotation the raw service key's role claim no longer resolves
// to 'service_role' — so we mint a real admin session (same as trux-inbox) and
// call the RPCs as that admin. Pushes go through the notify function, which
// authenticates on an exact service-key match (claim-independent).
import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { json } from '../_shared/auth.ts'

function svc(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
}

/** Mint a session for an active admin so RPCs run under my_role()='admin'. */
async function adminClient(s: SupabaseClient): Promise<SupabaseClient | null> {
  const { data: profs } = await s.from('profiles').select('id').eq('role', 'admin').eq('is_active', true).limit(10)
  if (!profs?.length) return null
  const ids = new Set((profs as { id: string }[]).map((p) => p.id))
  const { data: users } = await s.auth.admin.listUsers({ page: 1, perPage: 200 })
  const admin = users?.users?.find((u) => ids.has(u.id) && u.email)
  if (!admin?.email) return null
  const { data: link, error } = await s.auth.admin.generateLink({ type: 'magiclink', email: admin.email })
  if (error || !link?.properties?.hashed_token) return null
  const anonUrl = Deno.env.get('SUPABASE_URL')!
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const anon = createClient(anonUrl, anonKey)
  const { data: sess, error: vErr } = await anon.auth.verifyOtp({ type: 'magiclink', token_hash: link.properties.hashed_token })
  if (vErr || !sess.session) return null
  return createClient(anonUrl, anonKey, { global: { headers: { Authorization: `Bearer ${sess.session.access_token}` } } })
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

  const admin = await adminClient(s)
  if (!admin) return json({ error: 'No active admin to run the sentinel as' }, 500)

  const { data: scan, error: scanErr } = await admin.rpc('sentinel_scan')
  if (scanErr) return json({ error: scanErr.message }, 500)

  if (mode === 'brief') {
    const { data: sum } = await admin.rpc('sentinel_open_summary') as { data: { open?: number; critical?: number; top?: { severity: string; title: string }[] } | null }
    const openN = sum?.open ?? 0
    if (openN > 0) {
      const lines = (sum?.top ?? []).slice(0, 5).map((t) => `${t.severity === 'critical' ? '‼️' : '⚠️'} ${t.title}`).join('\n')
      await pushAdmins(s, `Forest daily brief — ${openN} open (${sum?.critical ?? 0} critical)`, lines || 'See the Forest feed.', false)
    }
    return json({ mode, summary: sum })
  }

  const { data: alerts } = await admin.rpc('sentinel_take_alerts') as { data: { title: string; detail: string }[] | null }
  for (const a of alerts ?? []) {
    await pushAdmins(s, `‼️ ${a.title}`, a.detail, true)
  }
  return json({ mode, scan, pushed: (alerts ?? []).length })
})

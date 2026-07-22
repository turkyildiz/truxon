// Public quote-request door for the truxon.com landing page.
// No auth (public form) — defenses: honeypot field, length caps, the same
// City+State-or-Zip validation the table enforces, and a per-IP cooldown.
// Each accepted request pushes a notification to every active admin.

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, json, withCors } from '../_shared/auth.ts'

function s(v: unknown, max = 120): string {
  return String(v ?? '').trim().slice(0, max)
}

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405)
  const body = await req.json().catch(() => ({})) as Record<string, unknown>

  // honeypot: real users never fill a hidden "website" field
  if (s(body.website)) return json({ ok: true })

  const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown'

  const row = {
    contact_name: s(body.contact_name),
    company: s(body.company),
    email: s(body.email),
    phone: s(body.phone, 40),
    origin_city: s(body.origin_city, 60),
    origin_state: s(body.origin_state, 20),
    origin_zip: s(body.origin_zip, 12),
    dest_city: s(body.dest_city, 60),
    dest_state: s(body.dest_state, 20),
    dest_zip: s(body.dest_zip, 12),
    equipment: s(body.equipment, 60),
    pickup_date: s(body.pickup_date, 10) || null,
    notes: s(body.notes, 1500),
  }
  if (!row.contact_name) return json({ error: 'Name is required.' }, 400)
  if (!row.email && !row.phone) return json({ error: 'An email or phone number is required.' }, 400)
  // either/or rule, per end: City+State OR Zip
  const originOk = row.origin_zip !== '' || (row.origin_city !== '' && row.origin_state !== '')
  const destOk = row.dest_zip !== '' || (row.dest_city !== '' && row.dest_state !== '')
  if (!originOk) return json({ error: 'Origin needs City + State, or a Zip code.' }, 400)
  if (!destOk) return json({ error: 'Destination needs City + State, or a Zip code.' }, 400)

  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  // Durable per-IP cooldown (30s) — shared across isolates, unlike the old
  // in-memory Map that reset on cold start (review LOW).
  const { data: allowed } = await svc.rpc('check_ip_rate_limit', {
    p_ip: ip, p_action: 'quote_request', p_max: 1, p_window: '00:00:30',
  })
  if (allowed === false) return json({ error: 'Please wait a moment before sending another request.' }, 429)

  const { error } = await svc.from('quote_requests').insert(row)
  if (error) return json({ error: 'Could not save your request — please try again.' }, 500)

  // best-effort push to every active admin
  try {
    const { data: admins } = await svc.from('profiles').select('id').eq('role', 'admin').eq('is_active', true)
    const origin = row.origin_zip || `${row.origin_city}, ${row.origin_state}`
    const dest = row.dest_zip || `${row.dest_city}, ${row.dest_state}`
    for (const a of (admins ?? []) as { id: string }[]) {
      await fetch(`${Deno.env.get('SUPABASE_URL')!}/functions/v1/notify`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'send', user_id: a.id,
          title: '💰 New quote request',
          body: `${row.contact_name}${row.company ? ` (${row.company})` : ''}: ${origin} → ${dest}`,
        }),
      }).catch(() => {})
    }
  } catch { /* best-effort */ }

  return json({ ok: true })
}))

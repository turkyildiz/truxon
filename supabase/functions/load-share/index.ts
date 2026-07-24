// Public status door for load share links (R9 #127/#133). GET ?t=<token> →
// read-only JSON for that ONE load: status, route, appointment times, coarse
// "near <city>" position while rolling, and whether a POD is on file. POST
// {t, rating, comment} records a single thumbs up/down once the load has
// delivered. Unauthenticated by design but bounded drive-share style: a token
// names exactly one load, revocable, expiring, rate-limited per IP.
import { createClient, SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { json, withCors } from '../_shared/auth.ts'

const gone = () => json({ error: 'This link is unavailable — it may have been revoked or expired.' }, 404)

async function resolveShare(svc: SupabaseClient, token: string) {
  if (!token || token.length < 16) return null
  const { data } = await svc
    .from('load_share_links')
    .select('id, load_id, revoked, expires_at')
    .eq('token', token)
    .maybeSingle()
  if (!data || data.revoked || new Date(data.expires_at as string).getTime() < Date.now()) return null
  return data as { id: number; load_id: number }
}

Deno.serve(withCors(async (req) => {
  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 'unknown'
  const { data: allowed } = await svc.rpc('check_ip_rate_limit', {
    p_ip: ip, p_action: 'load_share', p_max: 30, p_window: '00:01:00',
  })
  if (allowed === false) return json({ error: 'Too many requests — try again in a minute.' }, 429)

  if (req.method === 'GET') {
    const share = await resolveShare(svc, new URL(req.url).searchParams.get('t') ?? '')
    if (!share) return gone()
    const { data: l } = await svc
      .from('loads')
      .select('load_number, status, pickup_address, pickup_time, delivery_address, delivery_time, truck_id, customer:customers(company_name)')
      .eq('id', share.load_id)
      .maybeSingle()
    if (!l) return gone()

    // coarse position only while rolling, and only the geocoder's town text
    let near: string | null = null
    if (l.status === 'in_transit' && l.truck_id != null) {
      const { data: pos } = await svc
        .from('eld_vehicle_status')
        .select('calc_location, ts, vehicle:eld_vehicles!inner(truck_id)')
        .eq('vehicle.truck_id', l.truck_id)
        .gt('ts', new Date(Date.now() - 3 * 3600_000).toISOString())
        .order('ts', { ascending: false })
        .limit(1)
        .maybeSingle()
      near = (pos as { calc_location?: string } | null)?.calc_location || null
    }
    const { data: pod } = await svc
      .from('documents')
      .select('id')
      .eq('entity_type', 'load')
      .eq('entity_id', share.load_id)
      .eq('doc_type', 'POD')
      .limit(1)
      .maybeSingle()
    const { data: fb } = await svc.from('load_feedback').select('rating').eq('share_id', share.id).maybeSingle()

    return json({
      load_number: l.load_number,
      carrier: 'Aida Logistics',
      customer: (l.customer as { company_name?: string } | null)?.company_name ?? '',
      status: l.status,
      pickup: { address: l.pickup_address, time: l.pickup_time },
      delivery: { address: l.delivery_address, time: l.delivery_time },
      near,
      pod_on_file: !!pod,
      delivered: ['delivered', 'completed', 'billed'].includes(l.status as string),
      feedback: (fb as { rating?: string } | null)?.rating ?? null,
    })
  }

  if (req.method === 'POST') {
    const body = await req.json().catch(() => ({})) as { t?: string; rating?: string; comment?: string }
    const share = await resolveShare(svc, body.t ?? '')
    if (!share) return gone()
    if (body.rating !== 'up' && body.rating !== 'down') return json({ error: 'rating must be up or down' }, 400)
    const { data: l } = await svc.from('loads').select('status').eq('id', share.load_id).maybeSingle()
    if (!l || !['delivered', 'completed', 'billed'].includes(l.status as string)) {
      return json({ error: 'Feedback opens once the load is delivered.' }, 400)
    }
    const { error } = await svc.from('load_feedback').insert({
      load_id: share.load_id,
      share_id: share.id,
      rating: body.rating,
      comment: String(body.comment ?? '').slice(0, 500),
    })
    if (error) return json({ error: 'Feedback was already recorded for this link — thank you.' }, 409)
    return json({ ok: true })
  }

  return json({ error: 'Method not allowed' }, 405)
}))

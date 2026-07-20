// Geocoding (Northstar). Resolves freeform load stop addresses to lat/lon + state
// via the Google Geocoding API, caching every address so a repeated shipper is
// never re-billed. Writes both the geocode_cache and the load's denormalized
// pickup/delivery lat/lon/state with the service role.
//   {address}                       — geocode one address, return it (admin/dispatcher)
//   {mode:'load', load_id}          — geocode a load's two stops + write them back
//   {mode:'backfill', limit}        — geocode a bounded batch of ungeocoded loads (cron/admin)
// Trigger: cron (anon-bearer gate) or an admin/dispatcher call.

import { createClient, SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, json } from '../_shared/auth.ts'

function isCron(req: Request): boolean {
  try {
    const payload = JSON.parse(atob((req.headers.get('Authorization')?.replace('Bearer ', '').split('.')[1] ?? '').replace(/-/g, '+').replace(/_/g, '/')))
    const ref = new URL(Deno.env.get('SUPABASE_URL')!).hostname.split('.')[0]
    return payload?.role === 'anon' && payload?.ref === ref
  } catch { return false }
}

// Cache key: lowercase, strip punctuation noise, collapse whitespace.
function norm(addr: string): string {
  return addr.toLowerCase().replace(/[.,#]/g, ' ').replace(/\s+/g, ' ').trim()
}

interface Geo {
  formatted: string; lat: number | null; lon: number | null
  city: string; state: string; postal: string; country: string
  location_type: string; partial: boolean
}

// deno-lint-ignore no-explicit-any
function parseGoogle(result: any): Geo {
  const comp = (type: string, short = true): string => {
    const c = (result.address_components ?? []).find((a: { types: string[] }) => a.types.includes(type))
    return c ? (short ? c.short_name : c.long_name) : ''
  }
  const loc = result.geometry?.location ?? {}
  return {
    formatted: result.formatted_address ?? '',
    lat: typeof loc.lat === 'number' ? loc.lat : null,
    lon: typeof loc.lng === 'number' ? loc.lng : null,
    city: comp('locality', false) || comp('postal_town', false) || comp('sublocality', false),
    state: comp('administrative_area_level_1'),
    postal: comp('postal_code'),
    country: comp('country'),
    location_type: result.geometry?.location_type ?? '',
    partial: result.partial_match === true,
  }
}

// Resolve one address: cache first, then Google. `cached` reports whether this
// avoided a (billable) Google call. `geo` is null only for an empty address.
async function geocodeOne(addr: string, svc: SupabaseClient, key: string): Promise<{ geo: Geo | null; cached: boolean }> {
  const clean = (addr ?? '').trim()
  if (!clean) return { geo: null, cached: true }
  const nk = norm(clean)

  const { data: hit } = await svc.from('geocode_cache').select('*').eq('norm_address', nk).maybeSingle()
  if (hit) return { geo: hit as unknown as Geo, cached: true }

  const url = new URL('https://maps.googleapis.com/maps/api/geocode/json')
  url.searchParams.set('address', clean)
  url.searchParams.set('key', key)
  const resp = await fetch(url)
  const body = await resp.json().catch(() => ({}))
  if (body.status !== 'OK' || !Array.isArray(body.results) || body.results.length === 0) {
    // Cache a negative result too, so a bad address isn't retried every run.
    const empty: Geo = { formatted: '', lat: null, lon: null, city: '', state: '', postal: '', country: '', location_type: body.status ?? 'ZERO_RESULTS', partial: false }
    await svc.from('geocode_cache').upsert({ norm_address: nk, ...empty }, { onConflict: 'norm_address' })
    return { geo: empty, cached: false }
  }
  const geo = parseGoogle(body.results[0])
  await svc.from('geocode_cache').upsert({ norm_address: nk, ...geo }, { onConflict: 'norm_address' })
  return { geo, cached: false }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()

  if (!isCron(req)) {
    const userClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    })
    const { data: role } = await userClient.rpc('my_role')
    if (!['admin', 'dispatcher'].includes(role as string)) return json({ error: 'admin/dispatcher or cron only' }, 403)
  }

  const key = Deno.env.get('GOOGLE_MAPS_API_KEY')
  if (!key) return json({ error: 'GOOGLE_MAPS_API_KEY not configured' }, 200)
  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  const now = new Date().toISOString()

  // ---- single address ----
  if (typeof body.address === 'string' && !body.mode) {
    const { geo } = await geocodeOne(body.address, svc, key)
    return json({ geo })
  }

  // ---- one load's two stops ----
  if (body.mode === 'load' && body.load_id != null) {
    const { data: load } = await svc.from('loads').select('id, pickup_address, delivery_address').eq('id', body.load_id).single()
    if (!load) return json({ error: 'load not found' }, 404)
    const { geo: pu } = await geocodeOne(load.pickup_address ?? '', svc, key)
    const { geo: de } = await geocodeOne(load.delivery_address ?? '', svc, key)
    await svc.from('loads').update({
      pickup_lat: pu?.lat ?? null, pickup_lon: pu?.lon ?? null, pickup_state: pu?.state || null,
      delivery_lat: de?.lat ?? null, delivery_lon: de?.lon ?? null, delivery_state: de?.state || null,
      geocoded_at: now,
    }).eq('id', load.id)
    return json({ load_id: load.id, pickup: pu, delivery: de })
  }

  // ---- bounded backfill of ungeocoded loads ----
  const limit = Math.min(Math.max(Number(body.limit) || 40, 1), 100)
  const { data: loads } = await svc.from('loads')
    .select('id, pickup_address, delivery_address')
    .is('geocoded_at', null)
    .or('pickup_address.neq.,delivery_address.neq.')
    .order('delivery_time', { ascending: false, nullsFirst: false })
    .limit(limit)

  let done = 0, googleCalls = 0
  for (const l of loads ?? []) {
    const pu = await geocodeOne(l.pickup_address ?? '', svc, key)
    const de = await geocodeOne(l.delivery_address ?? '', svc, key)
    if (!pu.cached) googleCalls++
    if (!de.cached) googleCalls++
    await svc.from('loads').update({
      pickup_lat: pu.geo?.lat ?? null, pickup_lon: pu.geo?.lon ?? null, pickup_state: pu.geo?.state || null,
      delivery_lat: de.geo?.lat ?? null, delivery_lon: de.geo?.lon ?? null, delivery_state: de.geo?.state || null,
      geocoded_at: now,
    }).eq('id', l.id)
    done++
  }

  const { count: remaining } = await svc.from('loads')
    .select('id', { head: true, count: 'exact' })
    .is('geocoded_at', null)
    .or('pickup_address.neq.,delivery_address.neq.')

  return json({ geocoded: done, approx_google_calls: googleCalls, remaining: remaining ?? 0 })
})

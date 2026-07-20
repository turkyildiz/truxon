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

// Resolve one address: cache first, then Google.
//   ok=false  → transient failure (REQUEST_DENIED, quota, network) — NOT cached
//               and the caller must NOT stamp the load done, so it retries later.
//   cached    → whether a (billable) Google call was avoided.
//   geo=null  → empty address (nothing to do).
async function geocodeOne(addr: string, svc: SupabaseClient, key: string): Promise<{ geo: Geo | null; cached: boolean; ok: boolean }> {
  const clean = (addr ?? '').trim()
  if (!clean) return { geo: null, cached: true, ok: true }
  const nk = norm(clean)

  const { data: hit } = await svc.from('geocode_cache').select('*').eq('norm_address', nk).maybeSingle()
  if (hit) return { geo: hit as unknown as Geo, cached: true, ok: true }

  const url = new URL('https://maps.googleapis.com/maps/api/geocode/json')
  url.searchParams.set('address', clean)
  url.searchParams.set('key', key)
  let body: { status?: string; results?: unknown[] } = {}
  try {
    const resp = await fetch(url)
    body = await resp.json().catch(() => ({}))
  } catch {
    return { geo: null, cached: false, ok: false } // network error — transient
  }
  // A genuine "no such place" is cacheable; a config/quota/transient error is not.
  if (body.status === 'ZERO_RESULTS') {
    const empty: Geo = { formatted: '', lat: null, lon: null, city: '', state: '', postal: '', country: '', location_type: 'ZERO_RESULTS', partial: false }
    await svc.from('geocode_cache').upsert({ norm_address: nk, ...empty }, { onConflict: 'norm_address' })
    return { geo: empty, cached: false, ok: true }
  }
  if (body.status !== 'OK' || !Array.isArray(body.results) || body.results.length === 0) {
    return { geo: null, cached: false, ok: false } // REQUEST_DENIED / OVER_QUERY_LIMIT / UNKNOWN — retry later
  }
  const geo = parseGoogle(body.results[0])
  await svc.from('geocode_cache').upsert({ norm_address: nk, ...geo }, { onConflict: 'norm_address' })
  return { geo, cached: false, ok: true }
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
    const pu = await geocodeOne(load.pickup_address ?? '', svc, key)
    const de = await geocodeOne(load.delivery_address ?? '', svc, key)
    if (!pu.ok || !de.ok) return json({ load_id: load.id, error: 'geocoder unavailable (transient) — not stamped', pickup: pu.geo, delivery: de.geo }, 200)
    await svc.from('loads').update({
      pickup_lat: pu.geo?.lat ?? null, pickup_lon: pu.geo?.lon ?? null, pickup_state: pu.geo?.state || null,
      delivery_lat: de.geo?.lat ?? null, delivery_lon: de.geo?.lon ?? null, delivery_state: de.geo?.state || null,
      geocoded_at: now,
    }).eq('id', load.id)
    return json({ load_id: load.id, pickup: pu.geo, delivery: de.geo })
  }

  // ---- bounded backfill of ungeocoded loads ----
  const limit = Math.min(Math.max(Number(body.limit) || 40, 1), 100)
  const { data: loads } = await svc.from('loads')
    .select('id, pickup_address, delivery_address')
    .is('geocoded_at', null)
    .or('pickup_address.neq.,delivery_address.neq.')
    .order('delivery_time', { ascending: false, nullsFirst: false })
    .limit(limit)

  let done = 0, skipped = 0, googleCalls = 0
  for (const l of loads ?? []) {
    const pu = await geocodeOne(l.pickup_address ?? '', svc, key)
    const de = await geocodeOne(l.delivery_address ?? '', svc, key)
    if (!pu.cached) googleCalls++
    if (!de.cached) googleCalls++
    // A transient geocoder failure must not stamp the load done — leave it for
    // the next run so it retries once the key/quota recovers.
    if (!pu.ok || !de.ok) { skipped++; continue }
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

  return json({ geocoded: done, skipped_transient: skipped, approx_google_calls: googleCalls, remaining: remaining ?? 0 })
})

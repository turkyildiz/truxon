// TABLET DAY — OSM trucker-POI sync. Pulls truck stops, rest areas, and
// weigh stations for the continental US from Overpass ONCE (monthly cron),
// caches them in map_pois so tablets query our own DB, never Overpass.
// Three queries with pauses — a polite guest on a volunteer-run API.
import { createClient } from 'jsr:@supabase/supabase-js@2'
import { json, requireCron, withCors } from '../_shared/auth.ts'

// Primary + fallback mirror — the main instance 504s when busy.
const MIRRORS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
]
const US_BBOX = '24.5,-125.0,49.5,-66.5' // continental US (s,w,n,e)
const UA = 'truxon.com fleet app (dispatch@truxon.com)'

const QUERIES: Record<string, string> = {
  truck_stop: `[out:json][timeout:120];(nwr["highway"="services"]["hgv"!="no"](${US_BBOX});nwr["amenity"="fuel"]["hgv"="yes"](${US_BBOX});nwr["amenity"="truck_stop"](${US_BBOX}););out center 20000;`,
  rest_area: `[out:json][timeout:120];nwr["highway"="rest_area"](${US_BBOX});out center 20000;`,
  weigh_station: `[out:json][timeout:120];(nwr["amenity"="weighbridge"](${US_BBOX});nwr["highway"="weigh_station"](${US_BBOX}););out center 20000;`,
}

Deno.serve(withCors(async (req) => {
  if (!requireCron(req)) return json({ error: 'Not authorized' }, 401)
  const svc = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // body {kind} syncs one category (keeps each invocation inside edge wall
  // limits); the cron's empty body walks all three — partial progress
  // persists per-kind even if the last one hits the wall.
  let only: string | undefined
  try { only = (await req.json())?.kind } catch { /* empty body */ }

  const counts: Record<string, number> = {}
  for (const [kind, q] of Object.entries(QUERIES)) {
    if (only && kind !== only) continue
    try {
      let r: Response | null = null
      for (const mirror of MIRRORS) {
        r = await fetch(mirror, {
          method: 'POST',
          headers: { 'User-Agent': UA, 'Content-Type': 'application/x-www-form-urlencoded' },
          body: `data=${encodeURIComponent(q)}`,
          signal: AbortSignal.timeout(130_000),
        }).catch(() => null)
        if (r?.ok) break
      }
      if (!r?.ok) { counts[kind] = -(r?.status ?? 0); continue }
      const elements = (await r.json()).elements ?? []
      const rows = elements.map((e: {
        id: number; lat?: number; lon?: number
        center?: { lat: number; lon: number }; tags?: Record<string, string>
      }) => ({
        id: e.id,
        lat: e.lat ?? e.center?.lat,
        lon: e.lon ?? e.center?.lon,
        name: e.tags?.name ?? e.tags?.brand ?? '',
      })).filter((p: { lat?: number }) => p.lat != null)
      // chunked upserts keep each RPC payload modest
      let n = 0
      for (let i = 0; i < rows.length; i += 2000) {
        const { data } = await svc.rpc('upsert_map_pois', {
          p_kind: kind, p_rows: rows.slice(i, i + 2000),
        })
        n += (data as number) ?? 0
      }
      counts[kind] = n
      await new Promise((res) => setTimeout(res, 5000)) // pause between queries
    } catch (e) {
      counts[kind] = -1
      console.warn(`poi-sync ${kind}:`, e)
    }
  }
  return json({ synced: counts })
}))

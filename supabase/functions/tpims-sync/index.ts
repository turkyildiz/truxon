// TPIMS real-time truck parking sync (every 10 min, cron-keyed). Open state
// feeds only: KY + IL follow the MAASTO spec (static = locations, dynamic =
// live counts), IN publishes GeoJSON with counts in message1. Coordinates
// come from the static feeds and stick; dynamic updates refresh counts.
import { createClient } from 'jsr:@supabase/supabase-js@2'
import { json, requireCron, withCors } from '../_shared/auth.ts'

const UA = 'truxon.com fleet app (dispatch@truxon.com)'

async function fetchJson(url: string): Promise<unknown | null> {
  try {
    const r = await fetch(url, { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(20_000) })
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}

type Row = Record<string, unknown>

async function specState(state: string, staticUrl: string, dynamicUrl: string): Promise<Row[]> {
  const [stat, dyn] = await Promise.all([fetchJson(staticUrl), fetchJson(dynamicUrl)])
  const dynBy = new Map<string, Record<string, unknown>>()
  for (const d of (dyn as Record<string, unknown>[] | null) ?? []) {
    if (typeof d.siteId === 'string') dynBy.set(d.siteId, d)
  }
  const rows: Row[] = []
  for (const s of (stat as Record<string, unknown>[] | null) ?? []) {
    const loc = s.location as Record<string, unknown> | undefined
    const d = dynBy.get(String(s.siteId))
    if (!loc?.latitude) continue
    rows.push({
      site_id: s.siteId, state,
      name: s.name ?? '', lat: loc.latitude, lon: loc.longitude,
      capacity: s.capacity ?? d?.capacity ?? null,
      available: String(d?.reportedAvailable ?? ''),
      trend: String(d?.trend ?? ''), open: d?.open ?? null, trust: d?.trustData ?? null,
    })
  }
  return rows
}

async function indiana(): Promise<Row[]> {
  const gj = await fetchJson('https://content.trafficwise.org/json/tpims.json') as
    { features?: Array<{ geometry?: { coordinates?: number[] }; properties?: Record<string, unknown> }> } | null
  const rows: Row[] = []
  for (const f of gj?.features ?? []) {
    const c = f.geometry?.coordinates
    const p = f.properties ?? {}
    if (!c || c.length < 2) continue
    rows.push({
      site_id: `IN-${p.device_nbr ?? p.title}`, state: 'IN',
      name: p.title ?? '', lat: c[1], lon: c[0],
      capacity: null, available: String(p.message1 ?? ''),
      trend: '', open: true, trust: true,
    })
  }
  return rows
}

Deno.serve(withCors(async (req) => {
  if (!requireCron(req)) return json({ error: 'Not authorized' }, 401)
  const svc = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )
  const counts: Record<string, number> = {}
  const batches: Array<[string, Row[]]> = [
    ['KY', await specState('KY',
      'http://www.trimarc.org/dat/tpims/TPIMS_Static.json',
      'http://www.trimarc.org/dat/tpims/TPIMS_Dynamic.json')],
    ['IL', await specState('IL',
      'https://truckparking.travelmidwest.com/TPIMS_Static.json',
      'https://truckparking.travelmidwest.com/TPIMS_Dynamic.json')],
    ['IN', await indiana()],
  ]
  for (const [state, rows] of batches) {
    if (rows.length === 0) { counts[state] = 0; continue }
    const { data, error } = await svc.rpc('upsert_truck_parking', { p_rows: rows })
    counts[state] = error ? -1 : (data as number)
  }
  return json({ synced: counts })
}))

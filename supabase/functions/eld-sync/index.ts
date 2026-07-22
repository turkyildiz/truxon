// ELD telematics sync (Northstar). Pulls the DriveHOS partner feed and writes it
// into the eld_* tables with the service role.
//   default        — rosters + live vehicle/driver status (fast; run every ~15 min)
//   mode:'history' — GPS breadcrumb history sweep (heavier; run nightly)
// Trigger: cron (anon-bearer gate) or an admin "Sync now".

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { json, requireCron, withCors } from '../_shared/auth.ts'

const BASE = 'https://api.drivehos.app/v2'

function isCron(req: Request): boolean {
  return requireCron(req)
}

// deno-lint-ignore no-explicit-any
const n = (v: any): number | null => { if (v == null || v === '') return null; const x = Number(v); return Number.isFinite(x) ? x : null }
// keep the LAST row per key — the status feeds can repeat a vehicle/driver, and an
// upsert batch with a duplicate conflict key errors ("cannot affect row twice").
function dedupeBy<T>(rows: T[], key: (r: T) => string): T[] {
  const m = new Map<string, T>()
  for (const r of rows) { const k = key(r); if (k) m.set(k, r) }
  return [...m.values()]
}
// deno-lint-ignore no-explicit-any
const mmddyyyy = (d: Date): string => `${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}-${d.getUTCFullYear()}`

function headers(): HeadersInit {
  return {
    'X-API-Provider-Key': Deno.env.get('ELD_PROVIDER_KEY') ?? '',
    'X-API-Company-Key': Deno.env.get('ELD_COMPANY_KEY') ?? '',
  }
}

// deno-lint-ignore no-explicit-any
async function eld(path: string): Promise<any> {
  const res = await fetch(`${BASE}/${path}`, { headers: headers() })
  if (!res.ok) throw new Error(`ELD ${path} → ${res.status}`)
  const j = await res.json().catch(() => ({}))
  return j
}

// page through limit/page endpoints until a short page
// deno-lint-ignore no-explicit-any
async function pageAll(path: string, limit = 200, maxPages = 50): Promise<any[]> {
  const out: any[] = []
  for (let page = 1; page <= maxPages; page++) {
    const j = await eld(`${path}${path.includes('?') ? '&' : '?'}limit=${limit}&page=${page}`)
    const rows = Array.isArray(j?.data) ? j.data : []
    out.push(...rows)
    if (rows.length < limit) break
  }
  return out
}

Deno.serve(withCors(async (req) => {
  if (!isCron(req)) {
    const userClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    })
    const { data: role } = await userClient.rpc('my_role')
    if (role !== 'admin') return json({ error: 'admin or cron only' }, 403)
  }
  if (!Deno.env.get('ELD_PROVIDER_KEY') || !Deno.env.get('ELD_COMPANY_KEY')) return json({ skipped: 'ELD keys not configured' })
  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  const now = new Date().toISOString()

  // quick health read: what the fleet map will actually see
  if (body.mode === 'debug') {
    const cnt = async (t: string, f = '*') => (await svc.from(t).select(f, { count: 'exact', head: true })).count ?? 0
    const withGps = (await svc.from('eld_vehicle_status').select('vehicle_id', { count: 'exact', head: true }).not('lat', 'is', null)).count ?? 0
    const linked = (await svc.from('eld_vehicles').select('vehicle_id', { count: 'exact', head: true }).not('truck_id', 'is', null)).count ?? 0
    const { data: map } = await svc.from('eld_vehicles').select('number, truck_id, trucks(unit_number)').order('number').limit(20)
    return json({
      eld_vehicles: await cnt('eld_vehicles'), linked_to_trucks: linked,
      vehicle_status: await cnt('eld_vehicle_status'), status_with_gps: withGps,
      driver_status: await cnt('eld_driver_status'), location_history: await cnt('eld_location_history'),
      // deno-lint-ignore no-explicit-any
      unit_map: (map ?? []).map((m: any) => ({ eld: m.number, truck: m.trucks?.unit_number ?? null })),
    })
  }

  // idle probe: what does the breadcrumb status field actually carry, and is
  // speed-zero time distinguishable from engine-off? Read-only; informs
  // whether idle % is honestly derivable from this feed.
  if (body.mode === 'idle_probe') {
    const since = new Date(Date.now() - 7 * 86400_000).toISOString()
    const { data: rows } = await svc.from('eld_location_history')
      .select('status, speed').gt('ts', since).limit(20000)
    const byStatus = new Map<string, { n: number; zero: number; sum: number }>()
    for (const r of (rows ?? []) as { status: string | null; speed: number | null }[]) {
      const k = r.status ?? '(null)'
      const b = byStatus.get(k) ?? { n: 0, zero: 0, sum: 0 }
      b.n++; if (!r.speed) b.zero++; b.sum += Number(r.speed ?? 0)
      byStatus.set(k, b)
    }
    const { data: rawSample } = await svc.from('eld_vehicles').select('raw').not('raw', 'is', null).limit(1)
    return json({
      sampled: rows?.length ?? 0, since,
      statuses: Object.fromEntries([...byStatus].map(([k, b]) =>
        [k, { rows: b.n, speed_zero: b.zero, avg_speed: b.n ? +(b.sum / b.n).toFixed(1) : 0 }])),
      roster_raw_keys: rawSample?.[0]?.raw ? Object.keys(rawSample[0].raw as Record<string, unknown>) : [],
      roster_raw_sample: rawSample?.[0]?.raw ?? null,
    })
  }

  try {
    // ── rosters ──
    const vehicles = await pageAll('vehicles')
    const drivers = await pageAll('drivers')
    if (vehicles.length) {
      await svc.from('eld_vehicles').upsert(vehicles.map((v) => ({
        vehicle_id: v.vehicle_id, number: v.number ?? '', vin: v.vin ?? '',
        active: v.active ?? true, last_seen: now, raw: v,
      })), { onConflict: 'vehicle_id' })
    }
    if (drivers.length) {
      await svc.from('eld_drivers').upsert(drivers.map((d) => ({
        driver_id: d.driver_id, username: d.username ?? '', first_name: d.first_name ?? '',
        last_name: d.last_name ?? '', active: d.active ?? true, last_seen: now, raw: d,
      })), { onConflict: 'driver_id' })
    }
    await svc.rpc('eld_link_vehicles')

    // ── history sweep (nightly; end_days_ago windows a backfill without
    //    tripping the per-vehicle page guard) ──
    if (body.mode === 'history') {
      const days = Number(body.days) || 2
      const endOff = Number(body.end_days_ago) || 0
      const end = new Date(Date.now() - endOff * 86400000)
      const start = new Date(end.getTime() - days * 86400000)
      let inserted = 0
      for (const v of vehicles.filter((x) => x.active)) {
        let token = ''
        for (let guard = 0; guard < 40; guard++) {
          const qs = `start_date=${mmddyyyy(start)}&end_date=${mmddyyyy(end)}&limit=1000${token ? `&next_page_token=${encodeURIComponent(token)}` : ''}`
          const j = await eld(`vehicle-location-history/${v.vehicle_id}?${qs}`)
          const rows = Array.isArray(j?.data) ? j.data : []
          if (rows.length) {
            // deno-lint-ignore no-explicit-any
            await svc.from('eld_location_history').upsert(rows.map((r: any) => ({
              id: r.id, vehicle_id: v.vehicle_id, vehicle_number: r.vehicle_number ?? v.number,
              vin: r.vin ?? v.vin, lat: n(r.lat), lng: n(r.lng), speed: n(r.speed),
              direction: n(r.direction), status: r.status ?? null, calc_location: r.calc_location ?? null,
              ts: r.timestamp,
            })), { onConflict: 'id', ignoreDuplicates: true })
            inserted += rows.length
          }
          token = j?.next_page_token ?? ''
          if (!token || rows.length === 0) break
        }
      }
      await svc.rpc('eld_link_vehicles')
      return json({ ok: true, mode: 'history', vehicles: vehicles.length, breadcrumbs: inserted, days })
    }

    // ── live status (default) ──
    const vstatus = dedupeBy(await pageAll('latest-vehicle-status'), (s) => s.vehicle_id)
    const dstatus = dedupeBy(await pageAll('latest-driver-status'), (s) => s.driver_id)
    const errs: string[] = []

    // The status feeds can reference vehicles/drivers not in the roster page
    // (e.g. inactive units still reporting). Backfill roster stubs so the fleet
    // feed's joins see them — without overwriting real roster rows.
    const stubV = dedupeBy(vstatus.filter((s) => s.vehicle_id), (s) => s.vehicle_id).map((s) => ({
      vehicle_id: s.vehicle_id, number: s.number ?? '', vin: s.vin ?? '', active: true, last_seen: now,
    }))
    if (stubV.length) await svc.from('eld_vehicles').upsert(stubV, { onConflict: 'vehicle_id', ignoreDuplicates: true })
    const stubD = dedupeBy(dstatus.filter((s) => s.driver_id), (s) => s.driver_id).map((s) => ({
      driver_id: s.driver_id, username: s.username ?? '', active: true, last_seen: now,
    }))
    if (stubD.length) await svc.from('eld_drivers').upsert(stubD, { onConflict: 'driver_id', ignoreDuplicates: true })
    await svc.rpc('eld_link_vehicles')

    const vsRows = vstatus.filter((s) => s.vehicle_id).map((s) => ({
      vehicle_id: s.vehicle_id, eld_driver_id: s.driver_id || null, number: s.number ?? '', vin: s.vin ?? '',
      odometer: n(s.odometer), fuel_level: n(s.fuel_level), speed: n(s.speed),
      lat: n(s.lat), lon: n(s.lon), status: s.status ?? null, ts: s.timestamp || null,
      calc_location: s.calc_location ?? null, updated_at: now,
    }))
    if (vsRows.length) {
      const { error } = await svc.from('eld_vehicle_status').upsert(vsRows, { onConflict: 'vehicle_id' })
      if (error) errs.push(`vehicle_status: ${error.message}`)
    }
    const dsRows = dstatus.filter((s) => s.driver_id).map((s) => ({
      driver_id: s.driver_id, username: s.username ?? '', break_sec: n(s.break), drive_sec: n(s.drive),
      shift_sec: n(s.shift), cycle_sec: n(s.cycle), current_status: s.current_status ?? null, updated_at: now,
    }))
    if (dsRows.length) {
      const { error } = await svc.from('eld_driver_status').upsert(dsRows, { onConflict: 'driver_id' })
      if (error) errs.push(`driver_status: ${error.message}`)
    }
    return json({ ok: errs.length === 0, vehicles: vehicles.length, drivers: drivers.length, vehicle_status: vstatus.length, driver_status: dstatus.length, errors: errs })
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 502)
  }
}))

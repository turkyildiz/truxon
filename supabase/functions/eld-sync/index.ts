// ELD telematics sync (Northstar). Pulls the DriveHOS partner feed and writes it
// into the eld_* tables with the service role.
//   default        — rosters + live vehicle/driver status (fast; run every ~15 min)
//   mode:'history' — GPS breadcrumb history sweep (heavier; run nightly)
// Trigger: cron (anon-bearer gate) or an admin "Sync now".

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { json } from '../_shared/auth.ts'

const BASE = 'https://api.drivehos.app/v2'

function isCron(req: Request): boolean {
  try {
    const payload = JSON.parse(atob((req.headers.get('Authorization')?.replace('Bearer ', '').split('.')[1] ?? '').replace(/-/g, '+').replace(/_/g, '/')))
    const ref = new URL(Deno.env.get('SUPABASE_URL')!).hostname.split('.')[0]
    return payload?.role === 'anon' && payload?.ref === ref
  } catch { return false }
}

// deno-lint-ignore no-explicit-any
const n = (v: any): number | null => { if (v == null || v === '') return null; const x = Number(v); return Number.isFinite(x) ? x : null }
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

Deno.serve(async (req) => {
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

    // ── history sweep (nightly) ──
    if (body.mode === 'history') {
      const days = Number(body.days) || 2
      const end = new Date()
      const start = new Date(Date.now() - days * 86400000)
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
    const vstatus = await pageAll('latest-vehicle-status')
    const dstatus = await pageAll('latest-driver-status')
    if (vstatus.length) {
      await svc.from('eld_vehicle_status').upsert(vstatus.map((s) => ({
        vehicle_id: s.vehicle_id, eld_driver_id: s.driver_id ?? null, number: s.number ?? '', vin: s.vin ?? '',
        odometer: n(s.odometer), fuel_level: n(s.fuel_level), speed: n(s.speed),
        lat: n(s.lat), lon: n(s.lon), status: s.status ?? null, ts: s.timestamp ?? null,
        calc_location: s.calc_location ?? null, updated_at: now,
      })), { onConflict: 'vehicle_id' })
    }
    if (dstatus.length) {
      await svc.from('eld_driver_status').upsert(dstatus.map((s) => ({
        driver_id: s.driver_id, username: s.username ?? '', break_sec: n(s.break), drive_sec: n(s.drive),
        shift_sec: n(s.shift), cycle_sec: n(s.cycle), current_status: s.current_status ?? null, updated_at: now,
      })), { onConflict: 'driver_id' })
    }
    return json({ ok: true, vehicles: vehicles.length, drivers: drivers.length, vehicle_status: vstatus.length, driver_status: dstatus.length })
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 502)
  }
})

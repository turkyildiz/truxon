// FMCSA safety watch (#3). Pulls the carrier's FMCSA/SMS profile (safety rating,
// out-of-service rates, crashes) and BASIC scores from the QCMobile API and feeds
// them into carrier_safety_snapshot + safety_csa via fmcsa_record. Sentinel then
// nudges on a lost rating or a BASIC over threshold.
//
// Trigger: weekly cron (anon-bearer gate) or an admin pressing "Check now".
// The FMCSA data is public, read-only; the webKey lives only in the secret store.

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { json, requireCron, withCors } from '../_shared/auth.ts'
import { digits, lookupByDot, lookupByMc, nameMatches } from '../_shared/fmcsa.ts'

const BASE = 'https://mobile.fmcsa.dot.gov/qc/services'

function isCron(req: Request): boolean {
  return requireCron(req)
}

// deno-lint-ignore no-explicit-any
function normDate(v: any): string | null {
  if (v == null || v === '') return null
  if (typeof v === 'number') return new Date(v).toISOString().slice(0, 10)
  const s = String(v)
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10)
  const m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/) // MM/DD/YYYY
  if (m) return `${m[3]}-${m[1].padStart(2, '0')}-${m[2].padStart(2, '0')}`
  return null
}
// deno-lint-ignore no-explicit-any
const num = (v: any): number | null => {
  if (v == null || v === '') return null
  const n = Number(String(v).replace(/[^0-9.\-]/g, ''))
  return Number.isFinite(n) ? n : null
}

function mapBasic(code: string): string | null {
  const c = (code || '').toLowerCase()
  if (c.includes('unsafe')) return 'unsafe_driving'
  if (c.includes('hours') || c.includes('fatigued') || c.includes('hos')) return 'hos'
  if (c.includes('fitness')) return 'driver_fitness'
  if (c.includes('controlled') || c.includes('substance') || c.includes('alcohol')) return 'controlled_substances'
  if (c.includes('vehicle') || c.includes('maintenance')) return 'vehicle_maint'
  if (c.includes('hazmat') || c.includes('hazardous')) return 'hazmat'
  if (c.includes('crash')) return 'crash'
  return null
}

Deno.serve(withCors(async (req) => {
  // cron OR an admin ("Check now")
  if (!isCron(req)) {
    const userClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    })
    const { data: role } = await userClient.rpc('my_role')
    if (role !== 'admin') return json({ error: 'admin or cron only' }, 403)
  }

  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const webKey = Deno.env.get('FMCSA_WEBKEY')
  if (!webKey) return json({ skipped: 'no FMCSA_WEBKEY configured' })

  const body = await req.json().catch(() => ({})) as Record<string, unknown>

  // ── weekly customer authority sweep (R8): re-verify every customer that
  //    carries an MC/USDOT; the sentinel reads customer_fmcsa_checks ──
  if (body.mode === 'customers') {
    const { data: custs } = await svc.from('customers')
      .select('id, company_name, mc_number, usdot_number, do_not_use')
    let checked = 0, problems = 0
    for (const c of custs ?? []) {
      if (c.do_not_use) continue
      if (!digits(c.mc_number) && !digits(c.usdot_number)) continue
      const dotN = digits(c.usdot_number)
      const mcN = digits(c.mc_number)
      if (!dotN && !mcN) continue
      const carrier = dotN ? await lookupByDot(dotN, webKey) : await lookupByMc(mcN, webKey)
      if (!carrier) continue   // API hiccup or number vanished — no row update, stays stale
      // deno-lint-ignore no-explicit-any
      const oos = normDate((carrier as any).oosDate)
      const match = nameMatches(c.company_name, carrier.legalName) ||
        nameMatches(c.company_name, carrier.dbaName)
      const allowed = String(carrier.allowedToOperate ?? '')
      if (allowed === 'N' || oos || !match) problems++
      await svc.from('customer_fmcsa_checks').upsert({
        customer_id: c.id, checked_at: new Date().toISOString(),
        usdot: dotN, mc: mcN,
        legal_name: String(carrier.legalName ?? ''),
        allowed_to_operate: allowed, oos_date: oos,
        name_match: match, raw: carrier,
      }, { onConflict: 'customer_id' })
      checked++
    }
    return json({ mode: 'customers', checked, problems })
  }

  const { data: cs } = await svc.from('company_settings').select('usdot_number').eq('id', 1).single()
  const dot = String(cs?.usdot_number ?? '').replace(/\D/g, '')
  if (!dot) return json({ skipped: 'no USDOT number set in Settings' })

  // carrier profile
  const cRes = await fetch(`${BASE}/carriers/${dot}?webKey=${webKey}`)
  if (!cRes.ok) return json({ error: `FMCSA carrier fetch ${cRes.status}` }, 502)
  const cJson = await cRes.json().catch(() => ({}))
  const carrier = cJson?.content?.carrier
  if (!carrier) return json({ error: 'no carrier in FMCSA response (check the USDOT number)' }, 502)

  const snapshot: Record<string, unknown> = {
    snapshot_date: normDate(carrier.snapshotDate) ?? normDate(cJson.retrievalDate),
    dot_number: String(carrier.dotNumber ?? dot),
    legal_name: carrier.legalName ?? '',
    safety_rating: carrier.safetyRating ?? '',
    safety_rating_date: normDate(carrier.safetyRatingDate),
    review_date: normDate(carrier.reviewDate),
    allowed_to_operate: carrier.allowedToOperate ?? '',
    status_code: carrier.statusCode ?? '',
    oos_date: normDate(carrier.oosDate),
    driver_insp: num(carrier.driverInsp), driver_oos_insp: num(carrier.driverOosInsp),
    driver_oos_rate: num(carrier.driverOosRate), driver_oos_natl: num(carrier.driverOosRateNationalAverage),
    vehicle_insp: num(carrier.vehicleInsp), vehicle_oos_insp: num(carrier.vehicleOosInsp),
    vehicle_oos_rate: num(carrier.vehicleOosRate), vehicle_oos_natl: num(carrier.vehicleOosRateNationalAverage),
    crash_total: num(carrier.crashTotal), fatal_crash: num(carrier.fatalCrash),
    inj_crash: num(carrier.injCrash), towaway_crash: num(carrier.towawayCrash),
    total_drivers: num(carrier.totalDrivers), total_power_units: num(carrier.totalPowerUnits),
    iss_score: num(carrier.issScore),
    mcs150_outdated: carrier.mcs150Outdated === true || carrier.mcs150Outdated === 'Y' ? 'true' : 'false',
  }

  // BASIC / SMS scores
  const basics: { basic: string; percentile: number | null; measure: number | null; alert: boolean }[] = []
  try {
    const bRes = await fetch(`${BASE}/carriers/${dot}/basics?webKey=${webKey}`)
    if (bRes.ok) {
      const bJson = await bRes.json().catch(() => ({}))
      const rows = Array.isArray(bJson?.content) ? bJson.content : []
      for (const r of rows) {
        const b = r?.basic
        const code = mapBasic(b?.basicsType?.basicsCode ?? '')
        if (!b || !code) continue
        basics.push({
          basic: code,
          percentile: num(b.basicsPercentile),
          measure: num(b.measureValue),
          alert: String(b.exceededFMCSAInterventionThreshold ?? '').toUpperCase() === 'Y',
        })
      }
    }
  } catch { /* BASICs are best-effort; the snapshot still records */ }

  const { data: result, error } = await svc.rpc('fmcsa_record', { p_snapshot: snapshot, p_basics: basics })
  if (error) return json({ error: error.message }, 500)
  return json({ ok: true, dot, ...(result as Record<string, unknown>) })
}))

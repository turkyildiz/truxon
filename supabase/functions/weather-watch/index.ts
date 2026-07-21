// TABLET DAY — NWS severe-weather watch. Every 30 min (cron-keyed): for each
// truck that moved in the last 2h, ask api.weather.gov (public domain) for
// active Severe/Extreme alerts at its position; each NEW (alert, truck) pair
// is recorded and pushed to that driver's tablet. Extreme/tornado/blizzard
// class rides the urgent channel (DND-bypass alarm), the rest are normal
// pushes. Zero API keys, zero cost.
import { createClient } from 'jsr:@supabase/supabase-js@2'
import { json, requireCron, withCors } from '../_shared/auth.ts'

const NWS_UA = 'truxon.com fleet dispatch (dispatch@truxon.com)'
const URGENT_EVENTS = /tornado|blizzard|ice storm|extreme/i

Deno.serve(withCors(async (req) => {
  if (!requireCron(req)) return json({ error: 'Not authorized' }, 401)
  const svc = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  const { data: positions } = await svc
    .from('vehicle_position_current')
    .select('truck_id, driver_id, lat, lng, recorded_at')
    .gte('recorded_at', new Date(Date.now() - 2 * 3600_000).toISOString())
  if (!positions || positions.length === 0) return json({ checked: 0, alerts: 0, pushed: 0 })

  let alerts = 0
  let pushed = 0
  for (const p of positions) {
    if (p.lat == null || p.lng == null) continue
    let features: Array<{ id?: string; properties?: Record<string, unknown> }> = []
    try {
      const r = await fetch(
        `https://api.weather.gov/alerts/active?point=${p.lat},${p.lng}&status=actual&severity=Severe,Extreme`,
        { headers: { 'User-Agent': NWS_UA, Accept: 'application/geo+json' }, signal: AbortSignal.timeout(10_000) },
      )
      if (!r.ok) continue
      features = (await r.json()).features ?? []
    } catch { continue } // one dead-zone lookup never stops the sweep

    for (const f of features) {
      const props = f.properties ?? {}
      const alertId = String(f.id ?? props.id ?? '')
      if (!alertId) continue
      const { data: driver } = p.driver_id
        ? await svc.from('drivers').select('user_id').eq('id', p.driver_id).maybeSingle()
        : { data: null }
      const { data: inserted } = await svc
        .from('weather_alerts')
        .upsert({
          alert_id: alertId,
          truck_id: p.truck_id,
          driver_user_id: driver?.user_id ?? null,
          event: String(props.event ?? 'Weather alert'),
          severity: String(props.severity ?? ''),
          headline: String(props.headline ?? '').slice(0, 300),
          area: String(props.areaDesc ?? '').slice(0, 300),
          expires_at: props.expires ? String(props.expires) : null,
        }, { onConflict: 'alert_id,truck_id', ignoreDuplicates: true })
        .select('id')
      if (!inserted || inserted.length === 0) continue // already warned this truck
      alerts++

      if (driver?.user_id) {
        const urgent = URGENT_EVENTS.test(String(props.event ?? '')) ||
          String(props.severity ?? '') === 'Extreme'
        await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/notify`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            action: 'send',
            user_id: driver.user_id,
            title: `⛈ ${String(props.event ?? 'Weather alert')}`,
            body: String(props.headline ?? props.areaDesc ?? '').slice(0, 380),
            urgent,
          }),
        }).catch(() => {})
        pushed++
      }
    }
  }
  return json({ checked: positions.length, alerts, pushed })
}))

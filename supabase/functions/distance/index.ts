// Road distance via the Google Maps Directions API. Returns
// {miles: null, available: false} when no key is configured — the UI
// falls back to manual mileage entry.

import { corsResponse, getCaller, json } from '../_shared/auth.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()

  const caller = await getCaller(req)
  if (caller instanceof Response) return caller
  if (!['admin', 'dispatcher'].includes(caller.role)) {
    return json({ error: 'Not enough permissions' }, 403)
  }

  const { origin, destination, waypoints } = await req.json()
  const key = Deno.env.get('GOOGLE_MAPS_API_KEY')
  if (!key || !origin || !destination) return json({ miles: null, available: false })

  try {
    const url = new URL('https://maps.googleapis.com/maps/api/directions/json')
    url.searchParams.set('origin', origin)
    url.searchParams.set('destination', destination)
    // Multi-stop loads: intermediate stops in route order, capped at
    // Google's 25-waypoint limit.
    if (Array.isArray(waypoints) && waypoints.length > 0) {
      url.searchParams.set('waypoints', waypoints.filter((w: unknown) => typeof w === 'string' && w).slice(0, 25).join('|'))
    }
    url.searchParams.set('key', key)
    const resp = await fetch(url)
    const data = await resp.json()
    if (data.status !== 'OK') return json({ miles: null, available: false })
    const meters = data.routes[0].legs.reduce((sum: number, leg: { distance: { value: number } }) => sum + leg.distance.value, 0)
    return json({ miles: Math.round((meters / 1609.344) * 10) / 10, available: true })
  } catch {
    return json({ miles: null, available: false })
  }
})

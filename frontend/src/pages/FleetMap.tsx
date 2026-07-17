/**
 * Track & Trace — live map of every companion tablet, for dispatch/office.
 * Reads fleet_positions_snapshot (staff-only RPC) and polls every 20s.
 * Leaflet + OpenStreetMap tiles — no API key. Optional overlays:
 *   • Weather radar (RainViewer, free)
 *   • Severe-weather alerts (US NWS, free) — polygons + trucks-in-warning flag
 * Click a truck to draw its recent breadcrumb trail and center on it.
 */
import { useQuery } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState } from 'react'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { driverTrail, fleetPositionsSnapshot, type FleetPin } from '../data'
import { Card, PageHeader } from '../components/ui'

const FRESH = '#16a34a' // green — recent
const STALE = '#d97706' // amber — going cold
const ALERT = '#dc2626' // red — inside a severe-weather warning

function ageLabel(iso: string): { text: string; stale: boolean } {
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60_000)
  if (mins < 1) return { text: 'just now', stale: false }
  if (mins < 15) return { text: `${mins}m ago`, stale: false }
  if (mins < 60) return { text: `${mins}m ago`, stale: true }
  return { text: `${Math.floor(mins / 60)}h ago`, stale: true }
}

const mph = (mps: number | null) => (mps != null ? `${Math.round(mps * 2.23694)} mph` : '—')

function popupHtml(p: FleetPin, warned: boolean): string {
  const age = ageLabel(p.recorded_at)
  return `<div style="font:13px system-ui;line-height:1.5">
    <strong>${p.driver_name ?? 'Driver'}</strong>${warned ? ' ⚠️' : ''}<br/>
    Truck ${p.truck_unit ?? '—'} · Load ${p.load_number ?? '—'}<br/>
    ${mph(p.speed_mps)} · <span style="color:${age.stale ? STALE : '#64748b'}">${age.text}</span>
  </div>`
}

// ---- weather radar (RainViewer, key-less) ----
async function latestRadarPath(): Promise<string | null> {
  try {
    const r = await fetch('https://api.rainviewer.com/public/weather-maps.json')
    if (!r.ok) return null
    const j = await r.json()
    const past = j?.radar?.past ?? []
    return past[past.length - 1]?.path ?? null
  } catch {
    return null
  }
}

// ---- NWS severe alerts (key-less, US) ----
type AlertFeature = {
  geometry: { type: string; coordinates: unknown } | null
  properties: { event: string; severity: string; headline?: string }
}
async function fetchNwsAlerts(): Promise<AlertFeature[]> {
  try {
    const r = await fetch(
      'https://api.weather.gov/alerts/active?severity=Severe,Extreme&status=actual&limit=500',
      { headers: { Accept: 'application/geo+json' } },
    )
    if (!r.ok) return []
    const j = await r.json()
    return ((j.features ?? []) as AlertFeature[]).filter((f) => f.geometry)
  } catch {
    return []
  }
}

// ray-casting point-in-polygon; GeoJSON coords are [lng, lat]
function inRing(pt: [number, number], ring: number[][]): boolean {
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i][0], yi = ring[i][1], xj = ring[j][0], yj = ring[j][1]
    if (yi > pt[1] !== yj > pt[1] && pt[0] < ((xj - xi) * (pt[1] - yi)) / (yj - yi) + xi) inside = !inside
  }
  return inside
}
function inPolygon(pt: [number, number], poly: number[][][]): boolean {
  if (!poly.length || !inRing(pt, poly[0])) return false
  for (let h = 1; h < poly.length; h++) if (inRing(pt, poly[h])) return false // hole
  return true
}
function inFeature(lat: number, lng: number, f: AlertFeature): boolean {
  const g = f.geometry
  if (!g) return false
  const pt: [number, number] = [lng, lat]
  if (g.type === 'Polygon') return inPolygon(pt, g.coordinates as number[][][])
  if (g.type === 'MultiPolygon') return (g.coordinates as number[][][][]).some((p) => inPolygon(pt, p))
  return false
}

function MapCanvas({
  pins,
  weather,
  alerts,
  warnedIds,
}: {
  pins: FleetPin[]
  weather: boolean
  alerts: AlertFeature[]
  warnedIds: Set<number>
}) {
  const ref = useRef<HTMLDivElement>(null)
  const mapRef = useRef<L.Map | null>(null)
  const markersRef = useRef<L.LayerGroup | null>(null)
  const radarRef = useRef<L.TileLayer | null>(null)
  const alertsRef = useRef<L.GeoJSON | null>(null)
  const trailRef = useRef<L.LayerGroup | null>(null)

  useEffect(() => {
    if (!ref.current || mapRef.current) return
    const map = L.map(ref.current, { zoomControl: true }).setView([39.5, -98.35], 4)
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; OpenStreetMap contributors',
      maxZoom: 19,
    }).addTo(map)
    markersRef.current = L.layerGroup().addTo(map)
    trailRef.current = L.layerGroup().addTo(map)
    mapRef.current = map
    setTimeout(() => map.invalidateSize(), 100)
    return () => {
      map.remove()
      mapRef.current = null
    }
  }, [])

  // markers
  useEffect(() => {
    const map = mapRef.current
    const layer = markersRef.current
    if (!map || !layer) return
    layer.clearLayers()
    const latlngs: L.LatLngExpression[] = []
    for (const p of pins) {
      const warned = warnedIds.has(p.driver_id)
      const age = ageLabel(p.recorded_at)
      const color = warned ? ALERT : age.stale ? STALE : FRESH
      const marker = L.circleMarker([p.lat, p.lng], {
        radius: warned ? 10 : 8,
        color: '#ffffff',
        weight: 2,
        fillColor: color,
        fillOpacity: 0.95,
      })
      marker.bindPopup(popupHtml(p, warned))
      marker.bindTooltip(p.driver_name ?? '', { direction: 'top', offset: [0, -8] })
      marker.on('click', () => {
        map.setView([p.lat, p.lng], Math.max(map.getZoom(), 9))
        trailRef.current?.clearLayers()
        driverTrail(p.driver_id).then((pts) => {
          if (pts.length < 2 || !trailRef.current) return
          L.polyline(pts.map((t) => [t.lat, t.lng]), { color, weight: 3, opacity: 0.7, dashArray: '4 6' }).addTo(trailRef.current)
        })
      })
      marker.addTo(layer)
      latlngs.push([p.lat, p.lng])
    }
    if (latlngs.length === 1) map.setView(latlngs[0], 11)
    else if (latlngs.length > 1) map.fitBounds(L.latLngBounds(latlngs), { padding: [48, 48], maxZoom: 12 })
  }, [pins, warnedIds])

  // radar
  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    let cancelled = false
    if (radarRef.current) {
      map.removeLayer(radarRef.current)
      radarRef.current = null
    }
    if (!weather) return
    latestRadarPath().then((path) => {
      if (cancelled || !path || !mapRef.current) return
      const layer = L.tileLayer(`https://tilecache.rainviewer.com${path}/256/{z}/{x}/{y}/4/1_1.png`, {
        opacity: 0.6,
        attribution: 'Radar &copy; RainViewer',
        zIndex: 400,
      })
      layer.addTo(mapRef.current)
      radarRef.current = layer
    })
    return () => {
      cancelled = true
    }
  }, [weather])

  // severe-alert polygons
  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    if (alertsRef.current) {
      map.removeLayer(alertsRef.current)
      alertsRef.current = null
    }
    if (!alerts.length) return
    const gj = L.geoJSON(
      { type: 'FeatureCollection', features: alerts } as unknown as GeoJSON.FeatureCollection,
      {
        style: { color: ALERT, weight: 1, fillColor: ALERT, fillOpacity: 0.12 },
        onEachFeature: (f, l) =>
          l.bindPopup(`<strong>${f.properties?.event ?? 'Alert'}</strong><br/>${f.properties?.headline ?? ''}`),
      },
    )
    gj.addTo(map)
    alertsRef.current = gj
  }, [alerts])

  return <div ref={ref} className="mb-4 h-[60vh] min-h-80 w-full overflow-hidden rounded-xl border border-line" />
}

export default function FleetMap() {
  const [weather, setWeather] = useState(false)
  const [showAlerts, setShowAlerts] = useState(false)

  const { data: pins = [], isLoading, error } = useQuery({
    queryKey: ['fleet-positions'],
    queryFn: fleetPositionsSnapshot,
    refetchInterval: 20_000,
  })
  const { data: alerts = [] } = useQuery({
    queryKey: ['nws-alerts'],
    queryFn: fetchNwsAlerts,
    enabled: showAlerts,
    refetchInterval: 5 * 60_000,
  })

  const warnedIds = useMemo(() => {
    const s = new Set<number>()
    if (!showAlerts) return s
    for (const p of pins) if (alerts.some((f) => inFeature(p.lat, p.lng, f))) s.add(p.driver_id)
    return s
  }, [pins, alerts, showAlerts])

  const freshCount = useMemo(() => pins.filter((p) => !ageLabel(p.recorded_at).stale).length, [pins])

  return (
    <>
      <PageHeader
        title="Track & Trace"
        subtitle={
          pins.length
            ? `${pins.length} truck${pins.length > 1 ? 's' : ''} reporting · ${freshCount} live${warnedIds.size ? ` · ${warnedIds.size} in severe weather` : ''}`
            : 'Live position of every companion tablet'
        }
        actions={
          <div className="flex items-center gap-4">
            <label className="flex cursor-pointer items-center gap-2 text-sm text-body">
              <input type="checkbox" checked={weather} onChange={(e) => setWeather(e.target.checked)} /> 🌧️ Radar
            </label>
            <label className="flex cursor-pointer items-center gap-2 text-sm text-body">
              <input type="checkbox" checked={showAlerts} onChange={(e) => setShowAlerts(e.target.checked)} /> ⚠️ Severe alerts
            </label>
          </div>
        }
      />
      <Card>
        {isLoading ? (
          <p className="py-6 text-center text-muted">Loading positions…</p>
        ) : error ? (
          <p className="py-6 text-center text-sm text-muted">
            Fleet map unavailable — apply the companion migration and link drivers to logins.
          </p>
        ) : pins.length === 0 ? (
          <p className="py-6 text-center text-muted">
            No trucks reporting yet. Once a driver signs into the companion app, their truck appears here.
          </p>
        ) : (
          <>
            <MapCanvas pins={pins} weather={weather} alerts={showAlerts ? alerts : []} warnedIds={warnedIds} />
            <p className="mb-2 text-xs text-muted">Tap a truck to draw its recent trail. Green = live · amber = going cold · red = severe weather.</p>
            <div className="overflow-x-auto">
              <table className="min-w-full text-left text-sm">
                <thead className="border-b border-line text-xs uppercase text-muted">
                  <tr>
                    <th className="px-2 py-2">Driver</th>
                    <th className="px-2 py-2">Truck</th>
                    <th className="px-2 py-2">Load</th>
                    <th className="px-2 py-2">Position</th>
                    <th className="px-2 py-2">Speed</th>
                    <th className="px-2 py-2">Age</th>
                  </tr>
                </thead>
                <tbody>
                  {pins.map((p) => {
                    const age = ageLabel(p.recorded_at)
                    return (
                      <tr key={p.driver_id} className="border-b border-line">
                        <td className="px-2 py-2 font-medium">
                          {warnedIds.has(p.driver_id) && <span title="In a severe-weather warning">⚠️ </span>}
                          {p.driver_name}
                        </td>
                        <td className="px-2 py-2">{p.truck_unit ?? '—'}</td>
                        <td className="px-2 py-2">{p.load_number ?? '—'}</td>
                        <td className="px-2 py-2 font-mono text-xs">
                          {p.lat.toFixed(4)}, {p.lng.toFixed(4)}
                        </td>
                        <td className="px-2 py-2">{mph(p.speed_mps)}</td>
                        <td className={`px-2 py-2 ${age.stale ? 'font-semibold text-amber-600' : 'text-muted'}`}>{age.text}</td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </>
        )}
      </Card>
    </>
  )
}

/**
 * Track & Trace — live map of every companion tablet, for dispatch/office.
 * Reads fleet_positions_snapshot (staff-only RPC) and polls every 20s.
 * Uses Leaflet + OpenStreetMap tiles — no API key required.
 */
import { useQuery } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState } from 'react'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { fleetPositionsSnapshot, type FleetPin } from '../data'
import { Card, PageHeader } from '../components/ui'

// Free, key-less precipitation radar (RainViewer). We fetch the latest frame
// path and build a tile layer from it.
async function latestRadarPath(): Promise<string | null> {
  try {
    const r = await fetch('https://api.rainviewer.com/public/weather-maps.json')
    if (!r.ok) return null
    const j = await r.json()
    const frames = j?.radar?.past ?? []
    const last = frames[frames.length - 1]
    return last?.path ?? null
  } catch {
    return null
  }
}

const FRESH = '#16a34a' // green — moving/recent
const STALE = '#d97706' // amber — going cold

function ageLabel(iso: string): { text: string; stale: boolean } {
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60_000)
  if (mins < 1) return { text: 'just now', stale: false }
  if (mins < 15) return { text: `${mins}m ago`, stale: false }
  if (mins < 60) return { text: `${mins}m ago`, stale: true }
  return { text: `${Math.floor(mins / 60)}h ago`, stale: true }
}

function popupHtml(p: FleetPin): string {
  const age = ageLabel(p.recorded_at)
  const speed = p.speed_mps != null ? `${Math.round(p.speed_mps * 2.23694)} mph` : '—'
  return `<div style="font:13px system-ui;line-height:1.5">
    <strong>${p.driver_name ?? 'Driver'}</strong><br/>
    Truck ${p.truck_unit ?? '—'} · Load ${p.load_number ?? '—'}<br/>
    ${speed} · <span style="color:${age.stale ? STALE : '#64748b'}">${age.text}</span>
  </div>`
}

function MapCanvas({ pins, weather }: { pins: FleetPin[]; weather: boolean }) {
  const ref = useRef<HTMLDivElement>(null)
  const mapRef = useRef<L.Map | null>(null)
  const layerRef = useRef<L.LayerGroup | null>(null)
  const radarRef = useRef<L.TileLayer | null>(null)

  // Create the map once.
  useEffect(() => {
    if (!ref.current || mapRef.current) return
    const map = L.map(ref.current, { zoomControl: true }).setView([39.5, -98.35], 4)
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; OpenStreetMap contributors',
      maxZoom: 19,
    }).addTo(map)
    layerRef.current = L.layerGroup().addTo(map)
    mapRef.current = map
    // Leaflet needs a size recalc once the container has laid out.
    setTimeout(() => map.invalidateSize(), 100)
    return () => {
      map.remove()
      mapRef.current = null
      layerRef.current = null
    }
  }, [])

  // Redraw markers whenever positions change.
  useEffect(() => {
    const map = mapRef.current
    const layer = layerRef.current
    if (!map || !layer) return
    layer.clearLayers()
    const latlngs: L.LatLngExpression[] = []
    for (const p of pins) {
      const age = ageLabel(p.recorded_at)
      const color = age.stale ? STALE : FRESH
      const marker = L.circleMarker([p.lat, p.lng], {
        radius: 8,
        color: '#ffffff',
        weight: 2,
        fillColor: color,
        fillOpacity: 0.95,
      })
      marker.bindPopup(popupHtml(p))
      marker.bindTooltip(p.driver_name ?? '', { direction: 'top', offset: [0, -8] })
      marker.addTo(layer)
      latlngs.push([p.lat, p.lng])
    }
    if (latlngs.length === 1) {
      map.setView(latlngs[0], 11)
    } else if (latlngs.length > 1) {
      map.fitBounds(L.latLngBounds(latlngs), { padding: [48, 48], maxZoom: 12 })
    }
  }, [pins])

  // Precipitation radar overlay, toggled on/off. Refreshes the frame each time
  // it's switched on so it stays current.
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
      const layer = L.tileLayer(
        `https://tilecache.rainviewer.com${path}/256/{z}/{x}/{y}/4/1_1.png`,
        { opacity: 0.6, attribution: 'Radar &copy; RainViewer', zIndex: 400 },
      )
      layer.addTo(mapRef.current)
      radarRef.current = layer
    })
    return () => {
      cancelled = true
    }
  }, [weather])

  return <div ref={ref} className="mb-4 h-[60vh] min-h-80 w-full overflow-hidden rounded-xl border border-line" />
}

export default function FleetMap() {
  const { data: pins = [], isLoading, error } = useQuery({
    queryKey: ['fleet-positions'],
    queryFn: fleetPositionsSnapshot,
    refetchInterval: 20_000,
  })

  const freshCount = useMemo(() => pins.filter((p) => !ageLabel(p.recorded_at).stale).length, [pins])
  const [weather, setWeather] = useState(false)

  return (
    <>
      <PageHeader
        title="Track & Trace"
        subtitle={
          pins.length
            ? `${pins.length} truck${pins.length > 1 ? 's' : ''} reporting · ${freshCount} live now`
            : 'Live position of every companion tablet'
        }
        actions={
          <label className="flex cursor-pointer items-center gap-2 text-sm text-body">
            <input type="checkbox" checked={weather} onChange={(e) => setWeather(e.target.checked)} />
            🌧️ Weather radar
          </label>
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
          <MapCanvas pins={pins} weather={weather} />
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
                      <td className="px-2 py-2 font-medium">{p.driver_name}</td>
                      <td className="px-2 py-2">{p.truck_unit ?? '—'}</td>
                      <td className="px-2 py-2">{p.load_number ?? '—'}</td>
                      <td className="px-2 py-2 font-mono text-xs">
                        {p.lat.toFixed(4)}, {p.lng.toFixed(4)}
                      </td>
                      <td className="px-2 py-2">{p.speed_mps != null ? `${Math.round(p.speed_mps * 2.23694)} mph` : '—'}</td>
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

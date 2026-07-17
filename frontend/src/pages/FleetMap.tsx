/**
 * Live fleet pins for dispatch. Uses fleet_positions_snapshot RPC + 30s poll.
 * Optional Google Maps JS when VITE_GOOGLE_MAPS_JS_KEY is set; otherwise a table fallback.
 */
import { useQuery } from '@tanstack/react-query'
import { useEffect, useRef } from 'react'
import { fleetPositionsSnapshot, type FleetPin } from '../data'
import { Card } from '../components/ui'

const MAPS_KEY = import.meta.env.VITE_GOOGLE_MAPS_JS_KEY as string | undefined

// Minimal maps typings without @types/google.maps dependency
type GMap = { fitBounds: (b: unknown, p?: number) => void }
type GMarker = { setMap: (m: GMap | null) => void; addListener: (e: string, fn: () => void) => void }
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type GNS = any

function mapsNS(): GNS | undefined {
  return (window as unknown as { google?: { maps: GNS } }).google?.maps
}

function ageLabel(iso: string): { text: string; stale: boolean } {
  const ageMs = Date.now() - new Date(iso).getTime()
  const mins = Math.floor(ageMs / 60_000)
  if (mins < 1) return { text: 'just now', stale: false }
  if (mins < 15) return { text: `${mins}m ago`, stale: false }
  if (mins < 60) return { text: `${mins}m ago`, stale: true }
  return { text: `${Math.floor(mins / 60)}h ago`, stale: true }
}

function MapCanvas({ pins }: { pins: FleetPin[] }) {
  const ref = useRef<HTMLDivElement>(null)
  const mapRef = useRef<GMap | null>(null)
  const markersRef = useRef<GMarker[]>([])

  useEffect(() => {
    if (!MAPS_KEY || !ref.current) return
    let cancelled = false

    async function ensureMaps() {
      let g = mapsNS()
      if (!g) {
        await new Promise<void>((resolve, reject) => {
          const existing = document.querySelector('script[data-truxon-maps]')
          if (existing) {
            existing.addEventListener('load', () => resolve())
            return
          }
          const s = document.createElement('script')
          s.src = `https://maps.googleapis.com/maps/api/js?key=${MAPS_KEY}`
          s.async = true
          s.dataset.truxonMaps = '1'
          s.onload = () => resolve()
          s.onerror = () => reject(new Error('Maps script failed'))
          document.head.appendChild(s)
        })
        g = mapsNS()
      }
      if (cancelled || !ref.current || !g) return
      if (!mapRef.current) {
        mapRef.current = new g.Map(ref.current, {
          zoom: 5,
          center: { lat: 39.5, lng: -98.35 },
          mapTypeControl: false,
          streetViewControl: false,
        }) as GMap
      }
      markersRef.current.forEach((m) => m.setMap(null))
      markersRef.current = []
      const bounds = new g.LatLngBounds()
      for (const p of pins) {
        const age = ageLabel(p.recorded_at)
        const marker = new g.Marker({
          map: mapRef.current!,
          position: { lat: p.lat, lng: p.lng },
          title: p.driver_name,
          opacity: age.stale ? 0.55 : 1,
        }) as GMarker
        const info = new g.InfoWindow({
          content: `<div style="font:13px system-ui">
            <strong>${p.driver_name}</strong><br/>
            Truck: ${p.truck_unit ?? '—'} · Load: ${p.load_number ?? '—'}<br/>
            <span style="color:${age.stale ? '#b45309' : '#64748b'}">${age.text}</span>
          </div>`,
        })
        marker.addListener('click', () => info.open({ map: mapRef.current!, anchor: marker }))
        markersRef.current.push(marker)
        bounds.extend({ lat: p.lat, lng: p.lng })
      }
      if (pins.length > 0) mapRef.current.fitBounds(bounds, 48)
    }

    ensureMaps().catch(() => {
      /* table fallback still shown below */
    })
    return () => {
      cancelled = true
    }
  }, [pins])

  if (!MAPS_KEY) return null
  return <div ref={ref} className="mb-4 h-80 w-full overflow-hidden rounded-xl border border-line" />
}

export default function FleetMap() {
  const { data: pins = [], isLoading, error } = useQuery({
    queryKey: ['fleet-positions'],
    queryFn: fleetPositionsSnapshot,
    refetchInterval: 30_000,
  })

  return (
    <Card title="Live fleet">
      {isLoading ? (
        <p className="py-6 text-center text-muted">Loading positions…</p>
      ) : error ? (
        <p className="py-6 text-center text-sm text-muted">Fleet map unavailable (apply companion migration + link drivers).</p>
      ) : pins.length === 0 ? (
        <p className="py-6 text-center text-muted">No active GPS pins yet. Drivers go on duty or start a load in the companion app.</p>
      ) : (
        <>
          <MapCanvas pins={pins} />
          {!MAPS_KEY && (
            <p className="mb-3 text-xs text-muted">
              Set <code className="rounded bg-surface-2 px-1">VITE_GOOGLE_MAPS_JS_KEY</code> (browser key, referrer-restricted) for the map canvas.
            </p>
          )}
          <div className="overflow-x-auto">
            <table className="min-w-full text-left text-sm">
              <thead className="border-b text-xs uppercase text-muted">
                <tr>
                  <th className="px-2 py-2">Driver</th>
                  <th className="px-2 py-2">Truck</th>
                  <th className="px-2 py-2">Load</th>
                  <th className="px-2 py-2">Position</th>
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
                      <td className={`px-2 py-2 ${age.stale ? 'font-semibold text-amber-700' : 'text-muted'}`}>{age.text}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </Card>
  )
}

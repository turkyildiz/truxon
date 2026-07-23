import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useParams } from 'react-router-dom'
import DocsNotes from '../components/DocsNotes'
import StopsEditor, { emptyStop, type StopForm } from '../components/StopsEditor'
import { Badge, Button, Card, Field, formatDateTime, Input, LoadError, money, Select, Textarea } from '../components/ui'
import { addCheckCall, cancelLoad, changeLoadStatus, getLoad, listCheckCalls, listStops, loadRoute, nextLoadSuggestions, replaceStops, setLoadPaperwork, uncancelLoad, updateLoad } from '../data'
import { useEffect, useRef } from 'react'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { Link } from 'react-router-dom'

/** Deadhead assist: once a load is moving/done, show the closest open pickups. */
function NextLoadCard({ loadId, show }: { loadId: number; show: boolean }) {
  const q = useQuery({
    queryKey: ['next-load', loadId],
    queryFn: () => nextLoadSuggestions(loadId),
    enabled: show,
    retry: false,
  })
  const rows = q.data ?? []
  if (!show || q.isError || rows.length === 0) return null
  return (
    <Card title="🧭 Nearest next pickups (open, unassigned)">
      <table className="w-full text-sm">
        <tbody>
          {rows.map((s) => (
            <tr key={s.load_id} className="border-t border-edge/50">
              <td className="py-1.5 pr-3 font-medium">
                <Link className="text-brand hover:underline" to={`/loads/${s.load_id}`}>{s.load_number}</Link>
              </td>
              <td className="py-1.5 pr-3">{s.customer}</td>
              <td className="py-1.5 pr-3 text-muted">{s.pickup_address || s.pickup_state || '—'}</td>
              <td className="py-1.5 pr-3 font-semibold">{Math.round(Number(s.deadhead_miles))} mi deadhead</td>
              <td className="py-1.5">{money(Number(s.rate))}{s.rpm != null && <span className="text-muted"> (${Number(s.rpm).toFixed(2)}/mi)</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="mt-2 text-[11px] text-muted">Straight-line miles from this load's delivery — road miles run longer.</p>
    </Card>
  )
}
import { errorMessage } from '../supabase'
import { ReferenceDataBanner, useReferenceData } from '../useReferenceData'
import { LOAD_STATUSES, type Load } from '../types'

function StatusStepper({ load, onAdvance, busy }: { load: Load; onAdvance: (status: string) => void; busy: boolean }) {
  const currentIdx = LOAD_STATUSES.indexOf(load.status)
  return (
    <div className="flex flex-wrap items-center gap-2">
      {LOAD_STATUSES.map((s, i) => (
        <div key={s} className="flex items-center gap-2">
          {i > 0 && <div className={`h-0.5 w-4 ${i <= currentIdx ? 'bg-brand' : 'bg-line'}`} />}
          <span
            className={`rounded-full px-3 py-1.5 text-xs font-semibold ${
              i < currentIdx ? 'bg-brand/15 text-brand' : i === currentIdx ? 'bg-brand text-brand-fg' : 'bg-surface-2 text-muted'
            }`}
          >
            {s.replace('_', ' ')}
          </span>
        </div>
      ))}
      {currentIdx < LOAD_STATUSES.length - 1 && load.status !== 'completed' && (
        <Button className="ml-2 !py-1.5" disabled={busy} onClick={() => onAdvance(LOAD_STATUSES[currentIdx + 1])}>
          → {LOAD_STATUSES[currentIdx + 1].replace('_', ' ')}
        </Button>
      )}
      {currentIdx > 0 && load.status !== 'billed' && (
        <Button variant="secondary" className="!py-1.5" disabled={busy} onClick={() => onAdvance(LOAD_STATUSES[currentIdx - 1])}>
          ← back
        </Button>
      )}
    </div>
  )
}

/** The trail the truck actually drove — ELD breadcrumbs on a map. Renders
 * nothing for loads before the GPS bank started (2026-06-29). */
function RouteReplayCard({ loadId }: { loadId: number }) {
  const q = useQuery({ queryKey: ['load-route', loadId], queryFn: () => loadRoute(loadId), retry: false })
  const mapRef = useRef<HTMLDivElement>(null)
  const points = q.data?.points ?? []
  useEffect(() => {
    if (!mapRef.current || points.length < 2) return
    const map = L.map(mapRef.current, { zoomControl: true, attributionControl: false })
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 17 }).addTo(map)
    const line = L.polyline(points as [number, number][], { color: '#6366f1', weight: 3, opacity: 0.85 }).addTo(map)
    L.circleMarker(points[0], { radius: 6, color: '#16a34a', fillOpacity: 0.9 }).addTo(map).bindTooltip('Start')
    L.circleMarker(points[points.length - 1], { radius: 6, color: '#dc2626', fillOpacity: 0.9 }).addTo(map).bindTooltip('End')
    map.fitBounds(line.getBounds(), { padding: [24, 24] })
    return () => { map.remove() }
  }, [points])
  if (q.isError || points.length < 2) return null
  return (
    <Card title="🛰️ Route replay — what the truck actually drove">
      <p className="mb-2 text-xs text-muted">
        {q.data?.total_pings?.toLocaleString()} GPS pings from the ELD, pickup −2h through delivery +4h.
      </p>
      <div ref={mapRef} className="h-72 w-full overflow-hidden rounded-xl" />
    </Card>
  )
}


/** Timestamped dispatch timeline — check calls, append-only (R9 #121). */
function CheckCallLog({ loadId }: { loadId: number }) {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['checkcalls', loadId], queryFn: () => listCheckCalls(loadId), enabled: !!loadId, retry: false })
  const [note, setNote] = useState('')
  const add = useMutation({
    mutationFn: () => addCheckCall(loadId, note.trim()),
    onSuccess: () => { setNote(''); qc.invalidateQueries({ queryKey: ['checkcalls', loadId] }) },
  })
  if (q.isError) return null
  const rows = q.data ?? []
  return (
    <Card title={`📞 Check calls${rows.length ? ` (${rows.length})` : ''}`}>
      <form
        className="mb-3 flex gap-2"
        onSubmit={(e) => { e.preventDefault(); if (note.trim()) add.mutate() }}
      >
        <Input value={note} onChange={(e) => setNote(e.target.value)}
          placeholder="e.g. 0930 driver loaded, 4 pallets short — broker notified" className="flex-1" />
        <Button type="submit" disabled={add.isPending || !note.trim()}>Log</Button>
      </form>
      {rows.length === 0 ? (
        <p className="text-sm text-muted">No check calls yet — every broker call and status update belongs here, timestamped.</p>
      ) : (
        <ul className="space-y-1.5">
          {rows.map((c) => (
            <li key={c.id} className="flex gap-3 border-l-2 border-line pl-3 text-sm">
              <span className="shrink-0 text-xs text-muted">{formatDateTime(c.created_at)}</span>
              <span className="text-body">{c.note}</span>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}

export default function LoadDetail() {
  const { id } = useParams()
  const qc = useQueryClient()
  const [error, setError] = useState('')
  const [editForm, setEditForm] = useState<Record<string, string> | null>(null)
  const [editStops, setEditStops] = useState<StopForm[]>([])

  const loadQ = useQuery({ queryKey: ['load', id], queryFn: () => getLoad(id!) })
  const load = loadQ.data
  const stopsQ = useQuery({ queryKey: ['load-stops', id], queryFn: () => listStops(id!) })
  const itinerary = stopsQ.data ?? []
  const { customers, drivers, trucks, trailers, isError: refError, retry: retryRef } = useReferenceData()

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['load', id] })
    qc.invalidateQueries({ queryKey: ['activity', 'load', String(id)] })
    qc.invalidateQueries({ queryKey: ['trucks'] })
    qc.invalidateQueries({ queryKey: ['trailers'] })
  }

  const advance = useMutation({
    mutationFn: (status: string) => changeLoadStatus(id!, status as Load['status']),
    onSuccess: () => {
      setError('')
      refresh()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  const cancel = useMutation({
    mutationFn: (reason: string) => cancelLoad(id!, reason),
    onSuccess: () => {
      setError('')
      refresh()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  const uncancel = useMutation({
    mutationFn: () => uncancelLoad(id!),
    onSuccess: () => {
      setError('')
      refresh()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  const paperwork = useMutation({
    mutationFn: (awaiting: boolean) => setLoadPaperwork(Number(id), awaiting),
    onSuccess: () => { setError(''); refresh() },
    onError: (err) => setError(errorMessage(err)),
  })

  const saveEdit = useMutation({
    mutationFn: async (payload: Record<string, unknown>) => {
      const realStops = editStops.filter((s) => s.facility || s.address || s.time || s.reference)
      const firstPu = realStops.find((s) => s.stop_type === 'pickup')
      const lastDel = [...realStops].reverse().find((s) => s.stop_type === 'delivery')
      const line = (s?: StopForm) => (s ? [s.facility, s.address].filter(Boolean).join(', ') : '')
      Object.assign(payload, {
        pickup_address: line(firstPu),
        pickup_time: firstPu?.time || null,
        pickup_number: firstPu?.reference ?? '',
        delivery_address: line(lastDel),
        delivery_time: lastDel?.time || null,
        delivery_number: lastDel?.reference ?? '',
      })
      const updated = await updateLoad(id!, payload)
      await replaceStops(id!, realStops.map((s) => ({ stop_type: s.stop_type, facility: s.facility, address: s.address, stop_time: s.time || null, reference: s.reference })))
      return updated
    },
    onSuccess: () => {
      setEditForm(null)
      setError('')
      qc.invalidateQueries({ queryKey: ['load-stops', id] })
      refresh()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  if (loadQ.isError) return <LoadError error={loadQ.error} onRetry={() => loadQ.refetch()} />
  if (!load) return <p className="py-8 text-center text-muted">Loading…</p>

  // Billed loads are locked by billing; cancelled loads are locked server-side
  // until un-cancelled.
  const editable = load.status !== 'billed' && load.status !== 'cancelled'
  const cancellable = load.status === 'pending' || load.status === 'assigned' || load.status === 'in_transit'

  function promptCancel() {
    if (!load) return
    const reason = window.prompt(`Cancel ${load.load_number}? Reason (optional):`)
    if (reason !== null) cancel.mutate(reason.trim())
  }

  function startEdit() {
    if (!load) return
    setEditForm({
      customer_id: String(load.customer_id),
      reference_number: load.reference_number,
      equipment_type: load.equipment_type,
      empty_miles: String(load.empty_miles || ''),
      driver_id: load.driver_id ? String(load.driver_id) : '',
      truck_id: load.truck_id ? String(load.truck_id) : '',
      trailer_id: load.trailer_id ? String(load.trailer_id) : '',
      rate: String(load.rate),
      miles: String(load.miles),
      special_terms: load.special_terms,
      notes: load.notes,
    })
    // Edit the stored itinerary; loads that predate load_stops fall back to
    // the primary route fields.
    setEditStops(
      itinerary.length > 0
        ? itinerary.map((s) => ({ stop_type: s.stop_type, facility: s.facility, address: s.address, time: s.stop_time?.slice(0, 16) ?? '', reference: s.reference }))
        : [
            { ...emptyStop('pickup'), address: load.pickup_address, time: load.pickup_time?.slice(0, 16) ?? '', reference: load.pickup_number },
            { ...emptyStop('delivery'), address: load.delivery_address, time: load.delivery_time?.slice(0, 16) ?? '', reference: load.delivery_number },
          ],
    )
  }

  function submitEdit() {
    if (!editForm) return
    saveEdit.mutate(Object.fromEntries(Object.entries(editForm).map(([k, v]) => [k, v === '' ? null : v])))
  }

  return (
    <div className="space-y-4">
      <Card>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold text-body">{load.load_number}</h1>
            <p className="text-sm text-muted">
              {load.customer_name}
              {load.reference_number && <span className="ml-2 text-muted">· Broker # {load.reference_number}</span>}
            </p>
          </div>
          <div className="flex items-center gap-3">
            <Badge status={load.status} />
            {load.awaiting_paperwork && (
              <span className="inline-flex items-center gap-1 rounded-full bg-amber-500/15 px-2.5 py-1 text-xs font-semibold text-amber-600 dark:text-amber-300">
                📄 Awaiting paperwork
              </span>
            )}
            {editable && !editForm && (
              <Button variant="secondary" onClick={startEdit}>
                Edit
              </Button>
            )}
            {cancellable && !editForm && (
              <Button variant="danger" disabled={cancel.isPending} onClick={promptCancel}>
                Cancel Load
              </Button>
            )}
          </div>
        </div>
        <div className="mt-4">
          {load.status === 'cancelled' ? (
            <div className="flex flex-wrap items-center gap-3">
              {load.cancel_reason && <p className="text-sm text-muted">Reason: {load.cancel_reason}</p>}
              <Button variant="secondary" className="!py-1.5" disabled={uncancel.isPending} onClick={() => uncancel.mutate()}>
                Un-cancel
              </Button>
            </div>
          ) : (
            <StatusStepper load={load} onAdvance={(s) => advance.mutate(s)} busy={advance.isPending} />
          )}
          {editable && (
            load.awaiting_paperwork ? (
              <div className="mt-3 flex flex-wrap items-center gap-3 rounded-lg bg-amber-500/10 px-4 py-2.5">
                <span className="text-sm text-amber-700 dark:text-amber-300">📄 Booked — waiting on the final rate confirmation / paperwork.</span>
                <Button variant="secondary" className="!py-1.5" disabled={paperwork.isPending} onClick={() => paperwork.mutate(false)}>
                  Mark paperwork received
                </Button>
              </div>
            ) : (
              <button
                className="mt-3 text-sm text-muted hover:text-amber-600"
                disabled={paperwork.isPending}
                onClick={() => paperwork.mutate(true)}
              >
                📄 Flag as awaiting paperwork
              </button>
            )
          )}
        </div>
        {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
      </Card>

      {editForm ? (
        <Card title="Edit Load">
          <ReferenceDataBanner show={refError} onRetry={retryRef} />
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field label="Customer">
              <Select value={editForm.customer_id} onChange={(e) => setEditForm({ ...editForm, customer_id: e.target.value })}>
                {customers.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.company_name}
                  </option>
                ))}
              </Select>
            </Field>
            <Field label="Broker Load / PRO #">
              <Input value={editForm.reference_number} onChange={(e) => setEditForm({ ...editForm, reference_number: e.target.value })} />
            </Field>
            <StopsEditor stops={editStops} onChange={setEditStops} />
            <Field label="Driver">
              <Select value={editForm.driver_id} onChange={(e) => setEditForm({ ...editForm, driver_id: e.target.value })}>
                <option value="">—</option>
                {drivers.filter((d) => d.status === 'active').map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.full_name}
                  </option>
                ))}
              </Select>
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Truck">
                <Select value={editForm.truck_id} onChange={(e) => setEditForm({ ...editForm, truck_id: e.target.value })}>
                  <option value="">—</option>
                  {trucks.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.unit_number} ({t.status.replace('_', ' ')})
                    </option>
                  ))}
                </Select>
              </Field>
              <Field label="Trailer">
                <Select value={editForm.trailer_id} onChange={(e) => setEditForm({ ...editForm, trailer_id: e.target.value })}>
                  <option value="">—</option>
                  {trailers.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.unit_number} ({t.status.replace('_', ' ')})
                    </option>
                  ))}
                </Select>
              </Field>
            </div>
            <Field label="Rate ($)">
              <Input type="number" step="0.01" value={editForm.rate} onChange={(e) => setEditForm({ ...editForm, rate: e.target.value })} />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Miles">
                <Input type="number" step="0.1" value={editForm.miles} onChange={(e) => setEditForm({ ...editForm, miles: e.target.value })} />
              </Field>
              <Field label="Empty Miles">
                <Input type="number" step="0.1" value={editForm.empty_miles} onChange={(e) => setEditForm({ ...editForm, empty_miles: e.target.value })} />
              </Field>
            </div>
            <Field label="Equipment Type">
              <Input value={editForm.equipment_type} onChange={(e) => setEditForm({ ...editForm, equipment_type: e.target.value })} />
            </Field>
            <Field label="Special Terms" className="sm:col-span-2">
              <Textarea value={editForm.special_terms} onChange={(e) => setEditForm({ ...editForm, special_terms: e.target.value })} />
            </Field>
            <Field label="Notes" className="sm:col-span-2">
              <Textarea value={editForm.notes} onChange={(e) => setEditForm({ ...editForm, notes: e.target.value })} />
            </Field>
          </div>
          <div className="mt-4 flex justify-end gap-3">
            <Button variant="secondary" onClick={() => setEditForm(null)}>
              Cancel
            </Button>
            <Button onClick={submitEdit} disabled={saveEdit.isPending}>
              {saveEdit.isPending ? 'Saving…' : 'Save Changes'}
            </Button>
          </div>
        </Card>
      ) : (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <Card title={itinerary.length > 2 ? `Route (${itinerary.length} stops)` : 'Route'}>
            <dl className="space-y-3 text-sm">
              {itinerary.length > 0 ? (
                itinerary.map((s, i) => (
                  <div key={s.id ?? i}>
                    <dt className="text-xs font-semibold uppercase text-muted">
                      {s.stop_type === 'pickup' ? 'Pickup' : 'Delivery'}
                      {itinerary.filter((x) => x.stop_type === s.stop_type).length > 1 ? ` #${s.seq}` : ''}
                    </dt>
                    <dd>{[s.facility, s.address].filter(Boolean).join(', ') || '—'}</dd>
                    <dd className="text-muted">{formatDateTime(s.stop_time)}</dd>
                    {s.reference && <dd className="text-muted">{s.stop_type === 'pickup' ? 'PU' : 'Delivery'} # {s.reference}</dd>}
                  </div>
                ))
              ) : (
                <>
                  <div>
                    <dt className="text-xs font-semibold uppercase text-muted">Pickup</dt>
                    <dd>{load.pickup_address || '—'}</dd>
                    <dd className="text-muted">{formatDateTime(load.pickup_time)}</dd>
                    {load.pickup_number && <dd className="text-muted">PU # {load.pickup_number}</dd>}
                  </div>
                  <div>
                    <dt className="text-xs font-semibold uppercase text-muted">Delivery</dt>
                    <dd>{load.delivery_address || '—'}</dd>
                    <dd className="text-muted">{formatDateTime(load.delivery_time)}</dd>
                    {load.delivery_number && <dd className="text-muted">Delivery # {load.delivery_number}</dd>}
                  </div>
                </>
              )}
              {load.special_terms && (
                <div>
                  <dt className="text-xs font-semibold uppercase text-muted">Special Terms</dt>
                  <dd>{load.special_terms}</dd>
                </div>
              )}
            </dl>
          </Card>
          <Card title="Assignment & Money">
            <dl className="grid grid-cols-2 gap-3 text-sm">
              <div>
                <dt className="text-xs font-semibold uppercase text-muted">Driver</dt>
                <dd>{load.driver_name ?? '—'}</dd>
              </div>
              <div>
                <dt className="text-xs font-semibold uppercase text-muted">Truck / Trailer</dt>
                <dd>
                  {load.truck_unit ?? '—'} / {load.trailer_unit ?? '—'}
                </dd>
                {load.equipment_type && <dd className="text-muted">{load.equipment_type}</dd>}
              </div>
              <div>
                <dt className="text-xs font-semibold uppercase text-muted">Rate</dt>
                <dd className="text-lg font-bold text-body">{money(load.rate)}</dd>
              </div>
              <div>
                <dt className="text-xs font-semibold uppercase text-muted">Miles / RPM</dt>
                <dd>
                  {Number(load.miles).toLocaleString()} mi{' '}
                  {load.rate_per_mile != null && <span className="text-muted">(${load.rate_per_mile.toFixed(2)}/mi)</span>}
                  {Number(load.empty_miles) > 0 && <span className="text-muted"> · {Number(load.empty_miles).toLocaleString()} empty</span>}
                </dd>
              </div>
            </dl>
          </Card>
        </div>
      )}

      <NextLoadCard loadId={Number(id)} show={['in_transit', 'delivered', 'completed'].includes(load.status)} />

      <RouteReplayCard loadId={Number(id)} />
      <CheckCallLog loadId={Number(id)} />
      <DocsNotes entityType="load" entityId={id!} docTypes={['Rate Confirmation', 'BOL', 'POD', 'Photo', 'Other']} />
    </div>
  )
}

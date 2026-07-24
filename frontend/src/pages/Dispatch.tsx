import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useState, type FormEvent } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import StopsEditor, { emptyStop, type StopForm } from '../components/StopsEditor'
import { Button, Card, Field, Input, money, Select, Textarea, UndoToast } from '../components/ui'
import { calculateDistance, createCustomer, createLoad, customerExposure, customerRateProfile, deleteLoadTemplate, restoreLoadTemplate, eldFleetLive, estimateLoadMargin, extractPdf, fleetCostBasis, geocodeAddress, laneRateForRoute, listLoads, listLoadTemplates, loadEtaRisk, saveLoadLineItems, saveLoadTemplate, sentinelSummary, suggestAssignment, type EldFleetRow, type ExtractedLineItem, type ExtractedStop, type LoadTemplate } from '../data'
import { errorMessage } from '../supabase'
import { ReferenceDataBanner, useReferenceData } from '../useReferenceData'
import FleetMap from './FleetMap'

const EMPTY_FORM = {
  customer_id: '',
  reference_number: '',
  equipment_type: '',
  driver_id: '',
  truck_id: '',
  trailer_id: '',
  rate: '',
  miles: '',
  empty_miles: '',
  special_terms: '',
  notes: '',
}

const EMPTY_STOPS: StopForm[] = [emptyStop('pickup'), emptyStop('delivery')]

const stopLine = (s: StopForm) => [s.facility, s.address].filter(Boolean).join(', ')

/** "9h 40m" from HOS seconds remaining; null-safe. */
function hosLeft(sec: number | null | undefined): string | null {
  if (sec == null) return null
  const h = Math.floor(sec / 3600)
  const m = Math.round((sec % 3600) / 60)
  return `${h}h ${String(m).padStart(2, '0')}m`
}

/** Route order: pickups in sequence, then deliveries in sequence. */
function routeOf(stops: StopForm[]): { origin: string; destination: string; waypoints: string[] } {
  const ordered = [...stops.filter((s) => s.stop_type === 'pickup'), ...stops.filter((s) => s.stop_type === 'delivery')].filter(stopLine)
  const lines = ordered.map(stopLine)
  return { origin: lines[0] ?? '', destination: lines.at(-1) ?? '', waypoints: lines.slice(1, -1) }
}

/** Shift handoff: what's rolling, what's booked-but-unassigned, what's hot —
 * the one screen the next person reads before touching anything (R9 #122). */
function HandoffCard() {
  const rollingQ = useQuery({
    queryKey: ['handoff-loads'],
    queryFn: () => listLoads({ statuses: ['assigned', 'in_transit'] }),
    refetchInterval: 5 * 60_000, retry: false,
  })
  const sentQ = useQuery({ queryKey: ['handoff-sentinel'], queryFn: sentinelSummary, retry: false })
  const [open, setOpen] = useState(false)
  const rolling = rollingQ.data ?? []
  if (rollingQ.isError || rolling.length === 0) return null
  const unassigned = rolling.filter((l) => !l.driver_id)
  const s = sentQ.data
  return (
    <Card title={`🤝 Shift handoff — ${rolling.length} rolling${unassigned.length ? `, ${unassigned.length} unassigned` : ''}${s?.critical ? ` · ${s.critical} critical alert${s.critical === 1 ? '' : 's'}` : ''}`}>
      {!open ? (
        <button type="button" className="text-sm font-medium text-brand" onClick={() => setOpen(true)}>
          Show the board →
        </button>
      ) : (
        <>
          <table className="w-full text-sm">
            <tbody>
              {rolling.map((l) => (
                <tr key={l.id} className="border-t border-line">
                  <td className="px-2 py-1.5 font-medium">{l.load_number}</td>
                  <td className="px-2 py-1.5 text-muted">{l.customer_name}</td>
                  <td className="px-2 py-1.5">{l.driver_name ?? <span className="font-semibold text-amber-600 dark:text-amber-400">unassigned</span>}</td>
                  <td className="px-2 py-1.5 capitalize">{l.status.replace('_', ' ')}</td>
                  <td className="px-2 py-1.5 text-muted">
                    {l.status === 'assigned'
                      ? `PU ${l.pickup_time ? new Date(l.pickup_time).toLocaleString(undefined, { weekday: 'short', hour: 'numeric', minute: '2-digit' }) : '?'}`
                      : `DEL ${l.delivery_time ? new Date(l.delivery_time).toLocaleString(undefined, { weekday: 'short', hour: 'numeric', minute: '2-digit' }) : '?'}`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {s && s.top.length > 0 && (
            <p className="mt-2 text-xs text-muted">
              Hot: {s.top.slice(0, 3).map((t) => t.title).join(' · ')}
            </p>
          )}
        </>
      )}
    </Card>
  )
}

/** Loads that will miss their appointment while it's still fixable. */
function LateRiskCard() {
  const q = useQuery({ queryKey: ['eta-risk'], queryFn: loadEtaRisk, refetchInterval: 5 * 60_000, retry: false })
  const risky = (q.data ?? []).filter((l) => l.risk !== 'ok')
  if (q.isError || risky.length === 0) return null
  const label: Record<string, string> = { late: '🔴 LATE', hos_short: '🟠 HOS short', tight: '🟡 tight' }
  return (
    <Card title={`⏰ Late risk — ${risky.length} rolling load${risky.length === 1 ? '' : 's'}`}>
      <p className="mb-2 text-xs text-muted">
        Straight-line ×1.25 at 47 mph net vs the appointment — an estimate to act on, not a promise.
        Call the broker before they call you.
      </p>
      <table className="w-full text-sm">
        <tbody>
          {risky.map((l) => (
            <tr key={l.load_id} className="border-t border-line">
              <td className="px-2 py-1.5 font-medium">{l.load_number}</td>
              <td className="px-2 py-1.5 text-muted">{l.customer}</td>
              <td className="px-2 py-1.5">{l.driver ?? '—'}{l.unit ? ` · #${l.unit}` : ''}</td>
              <td className="px-2 py-1.5">{Math.round(Number(l.miles_to_go))} mi to go</td>
              <td className="px-2 py-1.5">appt {new Date(l.appointment).toLocaleString(undefined, { weekday: 'short', hour: 'numeric', minute: '2-digit' })}</td>
              <td className="px-2 py-1.5 font-semibold">{label[l.risk]}</td>
              <td className="px-2 py-1.5 text-muted">{l.risk === 'hos_short' ? `${l.hos_drive_h}h drive left` : `${l.slack_h}h slack`}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </Card>
  )
}

export default function Dispatch() {
  const navigate = useNavigate()
  const location = useLocation()
  const qc = useQueryClient()
  // (R9 #120) Clone: Loads' ⧉ button hands the lane over; dates, driver, and
  // truck are deliberately cleared — a clone is a NEW run, not a copy.
  const clone = (location.state as { clone?: Record<string, unknown> } | null)?.clone
  const [form, setForm] = useState(() => clone ? {
    ...EMPTY_FORM,
    customer_id: String(clone.customer_id ?? ''),
    equipment_type: String(clone.equipment_type ?? ''),
    rate: clone.rate != null ? String(clone.rate) : '',
    miles: clone.miles != null ? String(clone.miles) : '',
    empty_miles: clone.empty_miles != null ? String(clone.empty_miles) : '',
    special_terms: String(clone.special_terms ?? ''),
  } : { ...EMPTY_FORM })
  const [stops, setStops] = useState<StopForm[]>(() => clone ? [
    { ...emptyStop('pickup'), address: String(clone.pickup_address ?? '') },
    { ...emptyStop('delivery'), address: String(clone.delivery_address ?? '') },
  ] : EMPTY_STOPS.map((s) => ({ ...s })))
  const [error, setError] = useState('')
  const [aiNote, setAiNote] = useState('')
  const [lineItems, setLineItems] = useState<ExtractedLineItem[]>([])
  // R9 #118/#119: repeat lanes from templates (optionally on a cadence)
  const [tplName, setTplName] = useState('')
  const [tplCadence, setTplCadence] = useState<LoadTemplate['cadence']>('none')
  // R9 #161: template delete is soft — the undo toast restores it.
  const [deletedTpl, setDeletedTpl] = useState<LoadTemplate | null>(null)
  const templatesQ = useQuery({ queryKey: ['load-templates'], queryFn: listLoadTemplates, staleTime: 60_000, retry: false })

  function applyTemplate(t: LoadTemplate) {
    setForm({
      ...form,
      customer_id: t.customer_id != null ? String(t.customer_id) : form.customer_id,
      equipment_type: t.equipment_type || form.equipment_type,
      rate: t.rate != null ? String(t.rate) : form.rate,
      miles: t.miles != null ? String(t.miles) : form.miles,
      special_terms: t.special_terms || form.special_terms,
    })
    if (t.stops.length > 0) setStops(t.stops.map((s) => ({ stop_type: s.stop_type === 'delivery' ? 'delivery' as const : 'pickup' as const, facility: s.facility, address: s.address, time: '', reference: '' })))
    setAiNote(`✓ Template "${t.name}" applied — set the dates and go`)
  }

  const saveTpl = useMutation({
    mutationFn: () => saveLoadTemplate({
      name: tplName.trim(),
      customer_id: form.customer_id ? Number(form.customer_id) : null,
      equipment_type: form.equipment_type || '',
      rate: form.rate ? Number(form.rate) : null,
      miles: form.miles ? Number(form.miles) : null,
      pickup_address: stops.find((s) => s.stop_type === 'pickup')?.address ?? '',
      delivery_address: [...stops].reverse().find((s) => s.stop_type === 'delivery')?.address ?? '',
      special_terms: form.special_terms || '',
      stops: stops.filter((s) => s.facility || s.address).map((s) => ({ stop_type: s.stop_type, facility: s.facility, address: s.address })),
      cadence: tplCadence,
      next_run: tplCadence === 'none' ? null : new Date(Date.now() + 86400000).toISOString().slice(0, 10),
    }),
    onSuccess: () => {
      setTplName(''); setTplCadence('none')
      qc.invalidateQueries({ queryKey: ['load-templates'] })
      setAiNote('✓ Template saved' + (tplCadence !== 'none' ? ` — a ${tplCadence} draft will auto-appear (starting tomorrow, 6:10 AM)` : ''))
    },
    onError: (err) => setAiNote(errorMessage(err)),
  })
  const [distError, setDistError] = useState('')
  const [dragOver, setDragOver] = useState(false)
  /** Extracted customer name that matched nothing — offer add-or-pick. */
  const [pendingCustomer, setPendingCustomer] = useState<string | null>(null)

  const { customers, drivers, trucks, trailers, isError: refError, retry: retryRef } = useReferenceData()

  // Live HOS + position so the assignment picker knows who actually has hours
  // (refreshes with the 15-min ELD sync; stale-while-revalidate is fine here).
  const fleetQ = useQuery({ queryKey: ['eld-fleet-live'], queryFn: eldFleetLive, staleTime: 60_000, retry: false })
  const hosByDriver = new Map<number, EldFleetRow>()
  const liveByTruck = new Map<number, EldFleetRow>()
  for (const v of fleetQ.data ?? []) {
    if (v.driver_id != null && !hosByDriver.has(v.driver_id)) hosByDriver.set(v.driver_id, v)
    if (v.truck_id != null && !liveByTruck.has(v.truck_id)) liveByTruck.set(v.truck_id, v)
  }

  const extract = useMutation({
    mutationFn: async (file: File) => {
      const first = await extractPdf(file)
      if (first.needs_images) {
        // Scanned PDF — render the pages in the browser and let the vision
        // model read them.
        setAiNote('Scanned PDF — reading pages with vision AI…')
        const { renderPdfPages } = await import('../pdfPages')
        const pages = await renderPdfPages(file)
        if (pages.length > 0) return extractPdf(file, pages)
      }
      return first
    },
    onSuccess: (result) => {
      if (result.error && !result.fields) {
        setAiNote(result.error)
        return
      }
      const f = result.fields ?? {}
      // Try to match the extracted customer name against existing customers
      // (either direction: "TQL" ⊂ "Total Quality Logistics (TQL)" and back).
      const name = f.customer_name?.trim()
      const match = name
        ? customers.find((c) => {
            const a = c.company_name.toLowerCase()
            const b = name.toLowerCase()
            return a.includes(b.slice(0, 12)) || b.includes(a.slice(0, 12))
          })
        : undefined
      const merged = {
        ...form,
        customer_id: match ? String(match.id) : form.customer_id,
        reference_number: f.reference_number ?? form.reference_number,
        equipment_type: f.equipment_type ?? form.equipment_type,
        rate: f.rate != null ? String(f.rate) : form.rate,
        special_terms: f.special_terms ?? form.special_terms,
      }
      setForm(merged)
      // R9 #104: keep the printed rate breakdown — saved to load_line_items on create.
      setLineItems(Array.isArray(f.line_items) ? f.line_items : [])
      // Build the itinerary — prefer the full stops list, fall back to the
      // flat pickup/delivery fields.
      const extractedStops: ExtractedStop[] = Array.isArray(f.stops) && f.stops.length > 0 ? f.stops : []
      const toStop = (type: 'pickup' | 'delivery', addr?: string | null, time?: string | null, ref?: string | null): StopForm => ({
        stop_type: type,
        facility: '',
        address: addr ?? '',
        time: time?.slice(0, 16) ?? '',
        reference: ref ?? '',
      })
      const nextStops: StopForm[] = extractedStops.length
        ? extractedStops
            .filter((s) => s.address || s.facility)
            .map((s) => ({
              stop_type: s.type === 'delivery' ? 'delivery' : 'pickup',
              facility: s.facility ?? '',
              address: s.address ?? '',
              time: s.datetime?.slice(0, 16) ?? '',
              reference: s.reference ?? '',
            }))
        : [toStop('pickup', f.pickup_address, f.pickup_time, f.pickup_number), toStop('delivery', f.delivery_address, f.delivery_time, f.delivery_number)]
      if (nextStops.some((s) => s.address || s.facility)) setStops(nextStops)
      // Miles come from Google, not the paperwork — kick off the lookup as
      // soon as the route is known.
      const route = routeOf(nextStops)
      if (route.origin && route.destination) distance.mutate(route)
      setPendingCustomer(match || !name ? null : name)
      setAiNote(match || !name ? '✓ Fields extracted — review before saving' : '✓ Fields extracted — confirm the customer below')
    },
    onError: (err) => setAiNote(errorMessage(err)),
  })

  const distance = useMutation({
    mutationFn: (route: { origin: string; destination: string; waypoints?: string[] }) =>
      calculateDistance(route.origin, route.destination, route.waypoints ?? []),
    onSuccess: (d) => {
      setDistError('')
      if (d.miles != null) setForm((prev) => ({ ...prev, miles: String(d.miles) }))
      else setDistError('Distance service unavailable (no Google Maps API key) — enter miles manually.')
    },
    onError: (err) => setDistError(`Mileage lookup failed: ${errorMessage(err)} — enter miles manually.`),
  })

  /** R9 #115/#116: rank drivers for this pickup — deadhead priced so a
   * far-away assignment is a decision, not a surprise. */
  const suggest = useMutation({
    mutationFn: async () => {
      const pu = stops.find((s) => s.stop_type === 'pickup' && stopLine(s))
      if (!pu) throw new Error('Enter a pickup address first')
      const de = [...stops].reverse().find((s) => s.stop_type === 'delivery' && stopLine(s))
      const [pug, deg] = await Promise.all([
        geocodeAddress(stopLine(pu)),
        de ? geocodeAddress(stopLine(de)).catch(() => null) : Promise.resolve(null),
      ])
      if (pug.lat == null || pug.lon == null) throw new Error('Could not locate the pickup address')
      return suggestAssignment(pug.lat, pug.lon,
        pu.time ? new Date(pu.time).toISOString() : null,
        pug.state || null, deg?.state || null)
    },
  })

  /** Auto-fill miles when the route is known and miles is still empty. */
  function maybeAutoMiles() {
    const route = routeOf(stops)
    if (route.origin && route.destination && !form.miles && !distance.isPending) distance.mutate(route)
  }

  const addCustomer = useMutation({
    mutationFn: (name: string) => createCustomer({ company_name: name }),
    onSuccess: (c) => {
      qc.invalidateQueries({ queryKey: ['customers'] })
      setForm((prev) => ({ ...prev, customer_id: String(c.id) }))
      setPendingCustomer(null)
      setAiNote(`✓ Customer "${c.company_name}" added and selected — fill in billing details later from Customers`)
    },
    onError: (err) => setAiNote(errorMessage(err)),
  })

  const create = useMutation({
    mutationFn: () => {
      const realStops = stops.filter((s) => s.facility || s.address || s.time || s.reference)
      const pickups = realStops.filter((s) => s.stop_type === 'pickup')
      const dels = realStops.filter((s) => s.stop_type === 'delivery')
      const firstPu = pickups[0]
      const lastDel = dels.at(-1)
      const payload = Object.fromEntries(Object.entries(form).map(([k, v]) => [k, v === '' ? null : v]))
      Object.assign(payload, {
        pickup_address: firstPu ? stopLine(firstPu) : '',
        pickup_time: firstPu?.time || null,
        pickup_number: firstPu?.reference ?? '',
        delivery_address: lastDel ? stopLine(lastDel) : '',
        delivery_time: lastDel?.time || null,
        delivery_number: lastDel?.reference ?? '',
      })
      return createLoad(
        payload,
        realStops.map((s) => ({ stop_type: s.stop_type, facility: s.facility, address: s.address, stop_time: s.time || null, reference: s.reference })),
      )
    },
    onSuccess: async (load) => {
      if (lineItems.length > 0) await saveLoadLineItems(load.id, lineItems)
      navigate(`/loads/${load.id}`)
    },
    onError: (err) => setError(errorMessage(err)),
  })

  const onDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault()
      setDragOver(false)
      const file = e.dataTransfer.files?.[0]
      if (file?.type === 'application/pdf') extract.mutate(file)
      else setAiNote('Drop a PDF file')
    },
    [extract],
  )

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError('')
    create.mutate()
  }

  const rpm = form.rate && form.miles && parseFloat(form.miles) > 0 ? (parseFloat(form.rate) / parseFloat(form.miles)).toFixed(2) : null

  // Northstar: predicted margin, live as the rate/miles are entered.
  const { data: costBasis } = useQuery({ queryKey: ['fleet-cost-basis'], queryFn: fleetCostBasis, staleTime: 30 * 60 * 1000, retry: false })
  const rate = parseFloat(form.rate)
  const miles = parseFloat(form.miles)
  const margin = costBasis && rate > 0 && miles > 0
    ? estimateLoadMargin(rate, miles, parseFloat(form.empty_miles) || 0, costBasis)
    : null

  // Northstar: what this broker has historically paid us per mile.
  const custId = form.customer_id ? parseInt(form.customer_id, 10) : 0
  const { data: brokerRates } = useQuery({
    queryKey: ['customer-rate-profile', custId],
    queryFn: () => customerRateProfile(custId),
    enabled: custId > 0,
    staleTime: 10 * 60 * 1000,
    retry: false,
  })
  const brokerAvgRpm = brokerRates && brokerRates.load_count > 0 ? brokerRates.avg_rpm ?? null : null

  // Exposure guard: how much of our money this customer is already floating.
  const { data: exposure } = useQuery({
    queryKey: ['customer-exposure', custId],
    queryFn: () => customerExposure(custId),
    enabled: custId > 0,
    staleTime: 5 * 60 * 1000,
    retry: false,
  })
  const loadRpm = rate > 0 && miles > 0 ? rate / miles : null

  // Northstar: what this lane (origin→destination state) has historically paid.
  // Gated on miles being set so we geocode a stable route, not every keystroke.
  const laneRoute = routeOf(stops)
  const { data: laneRate } = useQuery({
    queryKey: ['lane-rate', laneRoute.origin, laneRoute.destination],
    queryFn: () => laneRateForRoute(laneRoute.origin, laneRoute.destination),
    enabled: laneRoute.origin.length > 4 && laneRoute.destination.length > 4 && miles > 0,
    staleTime: 30 * 60 * 1000,
    retry: false,
  })
  const laneAvgRpm = laneRate && laneRate.load_count > 0 ? laneRate.avg_rpm ?? null : null

  return (
    <div className="space-y-4">
      {deletedTpl && (
        <UndoToast
          message={`Template "${deletedTpl.name}" removed.`}
          onUndo={() => {
            void restoreLoadTemplate(deletedTpl.id)
              .then(() => qc.invalidateQueries({ queryKey: ['load-templates'] }))
              .catch((err) => setAiNote(errorMessage(err)))
            setDeletedTpl(null)
          }}
          onDismiss={() => setDeletedTpl(null)}
        />
      )}
      <FleetMap />
      <HandoffCard />
      <LateRiskCard />
      <Card title="AI-Assisted Dispatch">
        <div
          onDragOver={(e) => {
            e.preventDefault()
            setDragOver(true)
          }}
          onDragLeave={() => setDragOver(false)}
          onDrop={onDrop}
          className={`flex flex-col items-center justify-center rounded-xl border-2 border-dashed p-8 text-center transition-colors ${
            dragOver ? 'border-brand bg-brand/10' : 'border-line'
          }`}
        >
          <div className="text-3xl">📄</div>
          <p className="mt-2 text-sm font-medium">Drop a rate confirmation / load tender PDF here</p>
          <p className="text-xs text-muted">or</p>
          <label className="mt-2 cursor-pointer rounded-lg bg-navy-700 px-4 py-2 text-sm font-medium text-white hover:bg-navy-800">
            {extract.isPending ? 'Extracting…' : 'Choose PDF'}
            <input type="file" accept="application/pdf" className="hidden" onChange={(e) => e.target.files?.[0] && extract.mutate(e.target.files[0])} />
          </label>
          {aiNote && <p className="mt-3 text-sm text-brand">{aiNote}</p>}
        </div>
      </Card>

      {(templatesQ.data?.length ?? 0) > 0 && (
        <Card title="⧉ Repeat lanes">
          <div className="flex flex-wrap gap-2">
            {templatesQ.data!.map((t) => (
              <span key={t.id} className="inline-flex items-center gap-1 rounded-full border border-edge px-1 py-0.5">
                <button type="button" onClick={() => applyTemplate(t)}
                  className="rounded-full px-2 py-0.5 text-sm font-medium text-body hover:bg-slate-500/10"
                  title={`${t.pickup_address} → ${t.delivery_address}${t.rate != null ? ` · $${t.rate}` : ''}${t.cadence !== 'none' ? ` · repeats ${t.cadence}` : ''}`}>
                  {t.name}{t.cadence !== 'none' && ' 🔁'}
                </button>
                <button type="button" title="Remove template" className="px-1 text-xs text-muted hover:text-body"
                  onClick={() => deleteLoadTemplate(t.id).then(() => { setDeletedTpl(t); qc.invalidateQueries({ queryKey: ['load-templates'] }) }).catch((err) => setAiNote(errorMessage(err)))}>✕</button>
              </span>
            ))}
          </div>
        </Card>
      )}

      <Card title="Load Details">
        <ReferenceDataBanner show={refError} onRetry={retryRef} />
        <form onSubmit={onSubmit}>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <Field label="Customer *">
                <Select
                  required
                  value={form.customer_id}
                  onChange={(e) => {
                    setForm({ ...form, customer_id: e.target.value })
                    if (e.target.value) setPendingCustomer(null)
                  }}
                >
                  <option value="">Select customer…</option>
                  {customers.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.company_name}
                    </option>
                  ))}
                </Select>
              </Field>
              {exposure?.over_limit && (
                <p className="mt-1.5 rounded-lg bg-red-500/10 p-2 text-sm text-red-700 dark:text-red-300">
                  ⚠️ Exposure {money(Number(exposure.exposure))} exceeds this customer's{' '}
                  {money(Number(exposure.limit))} limit ({money(Number(exposure.open_ar))} open AR +{' '}
                  {money(Number(exposure.unbilled))} unbilled + {money(Number(exposure.open_loads))} in motion
                  {exposure.avg_days_to_pay != null && `; pays in ~${Math.round(Number(exposure.avg_days_to_pay))}d`}).
                  Booking more extends them further.
                </p>
              )}
              {pendingCustomer && (
                <p className="mt-1.5 rounded-lg bg-amber-500/10 p-2 text-sm text-amber-700 dark:text-amber-300">
                  "{pendingCustomer}" isn't in your customer list —{' '}
                  <button
                    type="button"
                    className="font-semibold underline"
                    disabled={addCustomer.isPending}
                    onClick={() => addCustomer.mutate(pendingCustomer)}
                  >
                    {addCustomer.isPending ? 'adding…' : 'add & select'}
                  </button>{' '}
                  or pick an existing customer above.
                </p>
              )}
            </div>
            <Field label="Broker Load / PRO #">
              <Input value={form.reference_number} onChange={(e) => setForm({ ...form, reference_number: e.target.value })} />
            </Field>

            <div className="flex items-end gap-3">
              <Field label="Rate ($)" className="flex-1">
                <Input type="number" step="0.01" value={form.rate} onChange={(e) => setForm({ ...form, rate: e.target.value })} />
                {lineItems.length > 0 && (
                  <p className="mt-1 text-xs text-muted-foreground">
                    Rate con itemizes: {lineItems.map((li) => `${li.description || li.kind} $${li.amount}`).join(' + ')}
                  </p>
                )}
              </Field>
              <Field label="Miles" className="flex-1">
                <Input type="number" step="0.1" value={form.miles} onChange={(e) => setForm({ ...form, miles: e.target.value })} />
              </Field>
              <Field label="Empty Mi." className="w-24">
                <Input type="number" step="0.1" value={form.empty_miles} onChange={(e) => setForm({ ...form, empty_miles: e.target.value })} />
              </Field>
              {rpm && <div className="pb-3 text-sm font-semibold text-brand">${rpm}/mi</div>}
            </div>

            {margin && (
              <div className={`rounded-lg border px-3 py-2 text-sm ${
                margin.verdict === 'loss' ? 'border-red-500/40 bg-red-500/10'
                : margin.verdict === 'thin' ? 'border-amber-500/40 bg-amber-500/10'
                : 'border-green-500/40 bg-green-500/10'
              }`}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className={`font-semibold ${
                    margin.verdict === 'loss' ? 'text-red-700 dark:text-red-300'
                    : margin.verdict === 'thin' ? 'text-amber-700 dark:text-amber-300'
                    : 'text-green-700 dark:text-green-300'
                  }`}>
                    {margin.verdict === 'loss' ? '⚠️ Predicted LOSS' : margin.verdict === 'thin' ? '➖ Thin margin' : '✅ Good margin'}
                    {' · '}est. net {money(margin.net)} ({margin.margin_pct.toFixed(0)}%)
                  </span>
                  <span className="text-xs text-muted">
                    ${margin.all_in_rpm.toFixed(2)}/mi all-in vs ${costBasis?.breakeven_rpm.toFixed(2)} breakeven
                  </span>
                </div>
                <div className="mt-1 text-xs text-muted">
                  On {Math.round(margin.total_miles)} mi: fuel {money(margin.fuel)} · driver {money(margin.driver)} · fixed {money(margin.fixed)}
                  {margin.tolls >= 1 ? ` · tolls ${money(margin.tolls)}` : ''} — a predicted estimate from your recent cost basis
                </div>
                {brokerAvgRpm != null && (
                  <div className="mt-1 border-t border-line/50 pt-1 text-xs text-muted">
                    📊 This broker has paid <span className="font-semibold text-body">${brokerAvgRpm.toFixed(2)}/mi</span> avg over{' '}
                    {brokerRates?.load_count} load{brokerRates?.load_count === 1 ? '' : 's'} (180 days)
                    {loadRpm != null && (
                      <span className={loadRpm >= brokerAvgRpm ? 'text-green-600 dark:text-green-400' : 'text-amber-600 dark:text-amber-400'}>
                        {' · '}this load ${Math.abs(loadRpm - brokerAvgRpm).toFixed(2)} {loadRpm >= brokerAvgRpm ? 'above' : 'below'} their norm
                      </span>
                    )}
                  </div>
                )}
                {laneAvgRpm != null && (
                  <div className="mt-1 text-xs text-muted">
                    🛣️ Lane {laneRate?.origin}→{laneRate?.dest} has paid <span className="font-semibold text-body">${laneAvgRpm.toFixed(2)}/mi</span> avg over{' '}
                    {laneRate?.load_count} load{laneRate?.load_count === 1 ? '' : 's'} (180 days)
                    {loadRpm != null && (
                      <span className={loadRpm >= laneAvgRpm ? 'text-green-600 dark:text-green-400' : 'text-amber-600 dark:text-amber-400'}>
                        {' · '}this load ${Math.abs(loadRpm - laneAvgRpm).toFixed(2)} {loadRpm >= laneAvgRpm ? 'above' : 'below'} the lane
                      </span>
                    )}
                  </div>
                )}
              </div>
            )}

            <div className="flex items-end gap-3 pb-1">
              <Button
                type="button"
                variant="secondary"
                className="!py-1.5 text-xs"
                disabled={!routeOf(stops).origin || !routeOf(stops).destination || distance.isPending}
                onClick={() => distance.mutate(routeOf(stops))}
              >
                {distance.isPending ? 'Calculating…' : '📍 Recalculate miles (all stops)'}
              </Button>
              {distError && <p className="pb-1 text-xs text-red-600">{distError}</p>}
            </div>

            <StopsEditor stops={stops} onChange={setStops} onRouteBlur={maybeAutoMiles} />

            <Field label="Equipment Type">
              <Input placeholder="53' Van, Reefer, Flatbed…" value={form.equipment_type} onChange={(e) => setForm({ ...form, equipment_type: e.target.value })} />
            </Field>
            <Field label="Driver">
              <Select value={form.driver_id} onChange={(e) => setForm({ ...form, driver_id: e.target.value })}>
                <option value="">Assign later</option>
                {drivers.filter((d) => d.status === 'active').map((d) => {
                  const live = hosByDriver.get(d.id)
                  const left = hosLeft(live?.hos_drive_sec)
                  return (
                    <option key={d.id} value={d.id}>
                      {d.full_name}
                      {left ? ` — ${left} drive left${live?.duty_status === 'DS_D' ? ' (driving now)' : ''}` : ''}
                    </option>
                  )
                })}
              </Select>
              {form.driver_id && (() => {
                const live = hosByDriver.get(Number(form.driver_id))
                if (!live) return null
                const drive = hosLeft(live.hos_drive_sec)
                const lowHours = (live.hos_drive_sec ?? Infinity) < 2 * 3600
                return (
                  <p className={`mt-1 text-xs ${lowHours ? 'text-amber-600 dark:text-amber-400' : 'text-muted'}`}>
                    {lowHours ? '⚠ ' : ''}HOS: {drive ?? '—'} drive · shift {hosLeft(live.hos_shift_sec) ?? '—'} · cycle{' '}
                    {hosLeft(live.hos_cycle_sec) ?? '—'}
                    {live.location ? ` · truck ${live.unit ?? '?'} near ${live.location}` : ''}
                  </p>
                )
              })()}
              <div className="mt-1">
                <Button type="button" disabled={suggest.isPending || !routeOf(stops).origin}
                  onClick={() => suggest.mutate()}>
                  {suggest.isPending ? 'Ranking drivers…' : '🎯 Suggest driver'}
                </Button>
                {suggest.isError && <p className="mt-1 text-xs text-red-600">{errorMessage(suggest.error)}</p>}
                {suggest.data && suggest.data.suggestions.length > 0 && (
                  <div className="mt-2 space-y-1">
                    {suggest.data.suggestions.slice(0, 5).map((s) => {
                      const costly = (s.reposition_cost ?? 0) >= 100
                      return (
                        <button type="button" key={s.driver_id}
                          onClick={() => setForm((prev) => ({ ...prev, driver_id: String(s.driver_id), truck_id: s.suggested_truck_id ? String(s.suggested_truck_id) : prev.truck_id }))}
                          className={`block w-full rounded border border-edge px-2 py-1 text-left text-xs hover:bg-surface-2 ${s.busy ? 'opacity-60' : ''}`}>
                          <span className="font-medium">{s.driver}</span>
                          {s.suggested_truck ? ` · truck ${s.suggested_truck}` : ''}
                          {s.deadhead_miles != null
                            ? <span className={costly ? 'font-semibold text-amber-600 dark:text-amber-400' : ''}>
                                {` — ${Number(s.deadhead_miles).toLocaleString()} mi deadhead${s.reposition_cost != null ? ` (~${money(s.reposition_cost)} to reposition)` : ''}`}
                              </span>
                            : ' — position unknown'}
                          {s.hos_drive_h != null ? ` · ${s.hos_drive_h}h drive left` : ''}
                          {s.lane_runs > 0 ? ` · ran this lane ×${s.lane_runs}` : ''}
                          {s.busy ? ` · on ${s.on_load ?? 'a load'}${s.free_at ? ` until ${new Date(s.free_at).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric' })}` : ''}` : ''}
                          {s.last_seen ? ` · last seen ${s.last_seen}` : ''}
                        </button>
                      )
                    })}
                    <p className="text-[11px] text-muted">{suggest.data.note}</p>
                  </div>
                )}
              </div>
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Truck">
                <Select value={form.truck_id} onChange={(e) => setForm({ ...form, truck_id: e.target.value })}>
                  <option value="">—</option>
                  {trucks.filter((t) => t.status === 'available' || String(t.id) === form.truck_id).map((t) => {
                    const live = liveByTruck.get(t.id)
                    return (
                      <option key={t.id} value={t.id}>
                        {t.unit_number}
                        {live?.location ? ` — ${live.location}` : ''}
                      </option>
                    )
                  })}
                </Select>
              </Field>
              <Field label="Trailer">
                <Select value={form.trailer_id} onChange={(e) => setForm({ ...form, trailer_id: e.target.value })}>
                  <option value="">—</option>
                  {trailers.filter((t) => t.status === 'available' || String(t.id) === form.trailer_id).map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.unit_number}
                    </option>
                  ))}
                </Select>
              </Field>
            </div>

            <Field label="Special Terms" className="sm:col-span-2">
              <Textarea value={form.special_terms} onChange={(e) => setForm({ ...form, special_terms: e.target.value })} />
            </Field>
            <Field label="Notes" className="sm:col-span-2">
              <Textarea value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
            </Field>
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
          <div className="mt-5 flex justify-end gap-3">
            <Button
              type="button"
              variant="secondary"
              onClick={() => {
                setForm({ ...EMPTY_FORM })
                setStops([emptyStop('pickup'), emptyStop('delivery')])
                setPendingCustomer(null)
                setDistError('')
                setAiNote('')
              }}
            >
              Clear
            </Button>
            <Button type="submit" disabled={create.isPending}>
              {create.isPending ? 'Creating…' : 'Create Load'}
            </Button>
          </div>
          <div className="mt-3 flex flex-wrap items-end gap-2 border-t border-edge pt-3">
            <Field label="Save this lane as a template" className="w-56">
              <Input value={tplName} onChange={(e) => setTplName(e.target.value)} placeholder="e.g. TQL Chicago→Nashville" />
            </Field>
            <Field label="Repeats" className="w-36">
              <Select value={tplCadence} onChange={(e) => setTplCadence(e.target.value as LoadTemplate['cadence'])}>
                <option value="none">No</option>
                <option value="weekly">Weekly</option>
                <option value="biweekly">Biweekly</option>
                <option value="monthly">Monthly</option>
              </Select>
            </Field>
            <Button type="button" variant="secondary" disabled={!tplName.trim() || saveTpl.isPending}
              onClick={() => saveTpl.mutate()}>
              {saveTpl.isPending ? 'Saving…' : 'Save template'}
            </Button>
            {tplCadence !== 'none' && (
              <p className="basis-full text-xs text-muted">Recurring templates auto-draft a pending load ({tplCadence}) at 6:10 AM — dispatch confirms with the broker before it rolls.</p>
            )}
          </div>
        </form>
      </Card>
    </div>
  )
}

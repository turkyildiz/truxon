import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { Button, Card, Field, Input, Select, Textarea } from '../components/ui'
import { calculateDistance, createCustomer, createLoad, extractPdf, listCustomers, listDrivers, trailersApi, trucksApi } from '../data'
import { errorMessage } from '../supabase'

const EMPTY_FORM = {
  customer_id: '',
  reference_number: '',
  pickup_number: '',
  delivery_number: '',
  pickup_address: '',
  pickup_time: '',
  delivery_address: '',
  delivery_time: '',
  driver_id: '',
  truck_id: '',
  trailer_id: '',
  rate: '',
  miles: '',
  special_terms: '',
  notes: '',
}

export default function Dispatch() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [form, setForm] = useState({ ...EMPTY_FORM })
  const [error, setError] = useState('')
  const [aiNote, setAiNote] = useState('')
  const [distError, setDistError] = useState('')
  const [dragOver, setDragOver] = useState(false)
  /** Extracted customer name that matched nothing — offer add-or-pick. */
  const [pendingCustomer, setPendingCustomer] = useState<string | null>(null)

  const customersQ = useQuery({ queryKey: ['customers', ''], queryFn: () => listCustomers() })
  const driversQ = useQuery({ queryKey: ['drivers', ''], queryFn: () => listDrivers() })
  const trucksQ = useQuery({ queryKey: ['trucks', ''], queryFn: () => trucksApi.list() })
  const trailersQ = useQuery({ queryKey: ['trailers', ''], queryFn: () => trailersApi.list() })
  const customers = customersQ.data ?? []
  const drivers = driversQ.data ?? []
  const trucks = trucksQ.data ?? []
  const trailers = trailersQ.data ?? []
  const sourceQueries = [customersQ, driversQ, trucksQ, trailersQ]

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
        pickup_number: f.pickup_number ?? form.pickup_number,
        delivery_number: f.delivery_number ?? form.delivery_number,
        pickup_address: f.pickup_address ?? form.pickup_address,
        pickup_time: f.pickup_time?.slice(0, 16) ?? form.pickup_time,
        delivery_address: f.delivery_address ?? form.delivery_address,
        delivery_time: f.delivery_time?.slice(0, 16) ?? form.delivery_time,
        rate: f.rate != null ? String(f.rate) : form.rate,
        special_terms: f.special_terms ?? form.special_terms,
      }
      setForm(merged)
      // Miles come from Google, not the paperwork — kick off the lookup as
      // soon as both addresses are known.
      if (merged.pickup_address && merged.delivery_address) {
        distance.mutate({ origin: merged.pickup_address, destination: merged.delivery_address })
      }
      setPendingCustomer(match || !name ? null : name)
      setAiNote(match || !name ? '✓ Fields extracted — review before saving' : '✓ Fields extracted — confirm the customer below')
    },
    onError: (err) => setAiNote(errorMessage(err)),
  })

  const distance = useMutation({
    mutationFn: (route: { origin: string; destination: string }) => calculateDistance(route.origin, route.destination),
    onSuccess: (d) => {
      setDistError('')
      if (d.miles != null) setForm((prev) => ({ ...prev, miles: String(d.miles) }))
      else setDistError('Distance service unavailable (no Google Maps API key) — enter miles manually.')
    },
    onError: (err) => setDistError(`Mileage lookup failed: ${errorMessage(err)} — enter miles manually.`),
  })

  /** Auto-fill miles when both addresses are set and miles is still empty. */
  function maybeAutoMiles() {
    if (form.pickup_address && form.delivery_address && !form.miles && !distance.isPending) {
      distance.mutate({ origin: form.pickup_address, destination: form.delivery_address })
    }
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
      const payload = Object.fromEntries(Object.entries(form).map(([k, v]) => [k, v === '' ? null : v]))
      return createLoad(payload)
    },
    onSuccess: (load) => navigate(`/loads/${load.id}`),
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

  return (
    <div className="space-y-4">
      <Card title="AI-Assisted Dispatch">
        <div
          onDragOver={(e) => {
            e.preventDefault()
            setDragOver(true)
          }}
          onDragLeave={() => setDragOver(false)}
          onDrop={onDrop}
          className={`flex flex-col items-center justify-center rounded-xl border-2 border-dashed p-8 text-center transition-colors ${
            dragOver ? 'border-navy-600 bg-navy-50' : 'border-slate-300'
          }`}
        >
          <div className="text-3xl">📄</div>
          <p className="mt-2 text-sm font-medium">Drop a rate confirmation / load tender PDF here</p>
          <p className="text-xs text-slate-500">or</p>
          <label className="mt-2 cursor-pointer rounded-lg bg-navy-700 px-4 py-2 text-sm font-medium text-white hover:bg-navy-800">
            {extract.isPending ? 'Extracting…' : 'Choose PDF'}
            <input type="file" accept="application/pdf" className="hidden" onChange={(e) => e.target.files?.[0] && extract.mutate(e.target.files[0])} />
          </label>
          {aiNote && <p className="mt-3 text-sm text-navy-700">{aiNote}</p>}
        </div>
      </Card>

      <Card title="Load Details">
        {sourceQueries.some((q) => q.isError) && (
          <p className="mb-3 rounded-lg bg-red-50 p-3 text-sm text-red-700">
            Some dropdown options failed to load — check your connection and{' '}
            <button type="button" className="font-medium underline" onClick={() => sourceQueries.forEach((q) => q.isError && q.refetch())}>
              retry
            </button>
            .
          </p>
        )}
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
              {pendingCustomer && (
                <p className="mt-1.5 rounded-lg bg-amber-50 p-2 text-sm text-amber-800">
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
              </Field>
              <Field label="Miles" className="flex-1">
                <Input type="number" step="0.1" value={form.miles} onChange={(e) => setForm({ ...form, miles: e.target.value })} />
              </Field>
              {rpm && <div className="pb-3 text-sm font-semibold text-navy-700">${rpm}/mi</div>}
            </div>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Pickup #">
                <Input value={form.pickup_number} onChange={(e) => setForm({ ...form, pickup_number: e.target.value })} />
              </Field>
              <Field label="Delivery #">
                <Input value={form.delivery_number} onChange={(e) => setForm({ ...form, delivery_number: e.target.value })} />
              </Field>
            </div>

            <Field label="Pickup Address">
              <Textarea
                value={form.pickup_address}
                onChange={(e) => setForm({ ...form, pickup_address: e.target.value })}
                onBlur={maybeAutoMiles}
              />
            </Field>
            <Field label="Delivery Address">
              <div className="space-y-2">
                <Textarea
                  value={form.delivery_address}
                  onChange={(e) => setForm({ ...form, delivery_address: e.target.value })}
                  onBlur={maybeAutoMiles}
                />
                <Button
                  type="button"
                  variant="secondary"
                  className="!py-1.5 text-xs"
                  disabled={!form.pickup_address || !form.delivery_address || distance.isPending}
                  onClick={() => distance.mutate({ origin: form.pickup_address, destination: form.delivery_address })}
                >
                  {distance.isPending ? 'Calculating…' : '📍 Recalculate miles'}
                </Button>
                {distError && <p className="text-xs text-red-600">{distError}</p>}
              </div>
            </Field>
            <Field label="Pickup Time">
              <Input type="datetime-local" value={form.pickup_time} onChange={(e) => setForm({ ...form, pickup_time: e.target.value })} />
            </Field>
            <Field label="Delivery Time">
              <Input type="datetime-local" value={form.delivery_time} onChange={(e) => setForm({ ...form, delivery_time: e.target.value })} />
            </Field>

            <Field label="Driver">
              <Select value={form.driver_id} onChange={(e) => setForm({ ...form, driver_id: e.target.value })}>
                <option value="">Assign later</option>
                {drivers.filter((d) => d.status === 'active').map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.full_name}
                  </option>
                ))}
              </Select>
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Truck">
                <Select value={form.truck_id} onChange={(e) => setForm({ ...form, truck_id: e.target.value })}>
                  <option value="">—</option>
                  {trucks.filter((t) => t.status === 'available' || String(t.id) === form.truck_id).map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.unit_number}
                    </option>
                  ))}
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
        </form>
      </Card>
    </div>
  )
}

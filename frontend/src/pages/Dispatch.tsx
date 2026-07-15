import { useMutation, useQuery } from '@tanstack/react-query'
import { useCallback, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { Button, Card, Field, Input, Select, Textarea } from '../components/ui'
import { calculateDistance, createLoad, extractPdf, listCustomers, listDrivers, trailersApi, trucksApi } from '../data'
import { errorMessage } from '../supabase'

const EMPTY_FORM = {
  customer_id: '',
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
  const [form, setForm] = useState({ ...EMPTY_FORM })
  const [error, setError] = useState('')
  const [aiNote, setAiNote] = useState('')
  const [dragOver, setDragOver] = useState(false)

  const { data: customers = [] } = useQuery({ queryKey: ['customers', ''], queryFn: () => listCustomers() })
  const { data: drivers = [] } = useQuery({ queryKey: ['drivers', ''], queryFn: () => listDrivers() })
  const { data: trucks = [] } = useQuery({ queryKey: ['trucks', ''], queryFn: () => trucksApi.list() })
  const { data: trailers = [] } = useQuery({ queryKey: ['trailers', ''], queryFn: () => trailersApi.list() })

  const extract = useMutation({
    mutationFn: extractPdf,
    onSuccess: (result) => {
      if (result.error && !result.fields) {
        setAiNote(result.error)
        return
      }
      const f = result.fields ?? {}
      // Try to match the extracted customer name against existing customers.
      const match = f.customer_name
        ? customers.find((c) => c.company_name.toLowerCase().includes(String(f.customer_name).toLowerCase().slice(0, 12)))
        : undefined
      setForm((prev) => ({
        ...prev,
        customer_id: match ? String(match.id) : prev.customer_id,
        pickup_address: f.pickup_address ?? prev.pickup_address,
        pickup_time: f.pickup_time?.slice(0, 16) ?? prev.pickup_time,
        delivery_address: f.delivery_address ?? prev.delivery_address,
        delivery_time: f.delivery_time?.slice(0, 16) ?? prev.delivery_time,
        rate: f.rate != null ? String(f.rate) : prev.rate,
        special_terms: f.special_terms ?? prev.special_terms,
      }))
      setAiNote(match || !f.customer_name ? '✓ Fields extracted — review before saving' : `✓ Extracted. Customer "${f.customer_name}" not found — pick or create it.`)
    },
    onError: (err) => setAiNote(errorMessage(err)),
  })

  const distance = useMutation({
    mutationFn: () => calculateDistance(form.pickup_address, form.delivery_address),
    onSuccess: (d) => {
      if (d.miles != null) setForm((prev) => ({ ...prev, miles: String(d.miles) }))
      else setAiNote('Distance service unavailable (no Google Maps API key) — enter miles manually.')
    },
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
        <form onSubmit={onSubmit}>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field label="Customer *">
              <Select required value={form.customer_id} onChange={(e) => setForm({ ...form, customer_id: e.target.value })}>
                <option value="">Select customer…</option>
                {customers.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.company_name}
                  </option>
                ))}
              </Select>
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

            <Field label="Pickup Address">
              <Textarea value={form.pickup_address} onChange={(e) => setForm({ ...form, pickup_address: e.target.value })} />
            </Field>
            <Field label="Delivery Address">
              <div className="space-y-2">
                <Textarea value={form.delivery_address} onChange={(e) => setForm({ ...form, delivery_address: e.target.value })} />
                <Button
                  type="button"
                  variant="secondary"
                  className="!py-1.5 text-xs"
                  disabled={!form.pickup_address || !form.delivery_address || distance.isPending}
                  onClick={() => distance.mutate()}
                >
                  {distance.isPending ? 'Calculating…' : '📍 Calculate miles'}
                </Button>
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
            <Button type="button" variant="secondary" onClick={() => setForm({ ...EMPTY_FORM })}>
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

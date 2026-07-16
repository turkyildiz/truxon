import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useParams } from 'react-router-dom'
import DocsNotes from '../components/DocsNotes'
import { Badge, Button, Card, Field, formatDateTime, Input, LoadError, money, Select, Textarea } from '../components/ui'
import { changeLoadStatus, getLoad, listCustomers, listDrivers, trailersApi, trucksApi, updateLoad } from '../data'
import { errorMessage } from '../supabase'
import { LOAD_STATUSES, type Load } from '../types'

function StatusStepper({ load, onAdvance, busy }: { load: Load; onAdvance: (status: string) => void; busy: boolean }) {
  const currentIdx = LOAD_STATUSES.indexOf(load.status)
  return (
    <div className="flex flex-wrap items-center gap-2">
      {LOAD_STATUSES.map((s, i) => (
        <div key={s} className="flex items-center gap-2">
          {i > 0 && <div className={`h-0.5 w-4 ${i <= currentIdx ? 'bg-navy-600' : 'bg-slate-300'}`} />}
          <span
            className={`rounded-full px-3 py-1.5 text-xs font-semibold ${
              i < currentIdx ? 'bg-navy-100 text-navy-700' : i === currentIdx ? 'bg-navy-700 text-white' : 'bg-slate-200 text-slate-500'
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

export default function LoadDetail() {
  const { id } = useParams()
  const qc = useQueryClient()
  const [error, setError] = useState('')
  const [editForm, setEditForm] = useState<Record<string, string> | null>(null)

  const loadQ = useQuery({ queryKey: ['load', id], queryFn: () => getLoad(id!) })
  const load = loadQ.data
  const driversQ = useQuery({ queryKey: ['drivers', ''], queryFn: () => listDrivers() })
  const trucksQ = useQuery({ queryKey: ['trucks', ''], queryFn: () => trucksApi.list() })
  const trailersQ = useQuery({ queryKey: ['trailers', ''], queryFn: () => trailersApi.list() })
  const customersQ = useQuery({ queryKey: ['customers', ''], queryFn: () => listCustomers() })
  const drivers = driversQ.data ?? []
  const trucks = trucksQ.data ?? []
  const trailers = trailersQ.data ?? []
  const customers = customersQ.data ?? []
  const sourceQueries = [driversQ, trucksQ, trailersQ, customersQ]

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

  const saveEdit = useMutation({
    mutationFn: (payload: Record<string, unknown>) => updateLoad(id!, payload),
    onSuccess: () => {
      setEditForm(null)
      setError('')
      refresh()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  if (loadQ.isError) return <LoadError error={loadQ.error} onRetry={() => loadQ.refetch()} />
  if (!load) return <p className="py-8 text-center text-slate-500">Loading…</p>

  const editable = load.status !== 'billed'

  function startEdit() {
    if (!load) return
    setEditForm({
      customer_id: String(load.customer_id),
      pickup_address: load.pickup_address,
      pickup_time: load.pickup_time?.slice(0, 16) ?? '',
      delivery_address: load.delivery_address,
      delivery_time: load.delivery_time?.slice(0, 16) ?? '',
      driver_id: load.driver_id ? String(load.driver_id) : '',
      truck_id: load.truck_id ? String(load.truck_id) : '',
      trailer_id: load.trailer_id ? String(load.trailer_id) : '',
      rate: String(load.rate),
      miles: String(load.miles),
      special_terms: load.special_terms,
      notes: load.notes,
    })
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
            <h1 className="text-xl font-bold text-navy-800">{load.load_number}</h1>
            <p className="text-sm text-slate-500">{load.customer_name}</p>
          </div>
          <div className="flex items-center gap-3">
            <Badge status={load.status} />
            {editable && !editForm && (
              <Button variant="secondary" onClick={startEdit}>
                Edit
              </Button>
            )}
          </div>
        </div>
        <div className="mt-4">
          <StatusStepper load={load} onAdvance={(s) => advance.mutate(s)} busy={advance.isPending} />
        </div>
        {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
      </Card>

      {editForm ? (
        <Card title="Edit Load">
          {sourceQueries.some((q) => q.isError) && (
            <p className="mb-3 rounded-lg bg-red-50 p-3 text-sm text-red-700">
              Some dropdown options failed to load — check your connection and{' '}
              <button type="button" className="font-medium underline" onClick={() => sourceQueries.forEach((q) => q.isError && q.refetch())}>
                retry
              </button>
              .
            </p>
          )}
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
            <div />
            <Field label="Pickup Address">
              <Textarea value={editForm.pickup_address} onChange={(e) => setEditForm({ ...editForm, pickup_address: e.target.value })} />
            </Field>
            <Field label="Delivery Address">
              <Textarea value={editForm.delivery_address} onChange={(e) => setEditForm({ ...editForm, delivery_address: e.target.value })} />
            </Field>
            <Field label="Pickup Time">
              <Input type="datetime-local" value={editForm.pickup_time} onChange={(e) => setEditForm({ ...editForm, pickup_time: e.target.value })} />
            </Field>
            <Field label="Delivery Time">
              <Input type="datetime-local" value={editForm.delivery_time} onChange={(e) => setEditForm({ ...editForm, delivery_time: e.target.value })} />
            </Field>
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
            <Field label="Miles">
              <Input type="number" step="0.1" value={editForm.miles} onChange={(e) => setEditForm({ ...editForm, miles: e.target.value })} />
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
          <Card title="Route">
            <dl className="space-y-3 text-sm">
              <div>
                <dt className="text-xs font-semibold uppercase text-slate-500">Pickup</dt>
                <dd>{load.pickup_address || '—'}</dd>
                <dd className="text-slate-500">{formatDateTime(load.pickup_time)}</dd>
              </div>
              <div>
                <dt className="text-xs font-semibold uppercase text-slate-500">Delivery</dt>
                <dd>{load.delivery_address || '—'}</dd>
                <dd className="text-slate-500">{formatDateTime(load.delivery_time)}</dd>
              </div>
              {load.special_terms && (
                <div>
                  <dt className="text-xs font-semibold uppercase text-slate-500">Special Terms</dt>
                  <dd>{load.special_terms}</dd>
                </div>
              )}
            </dl>
          </Card>
          <Card title="Assignment & Money">
            <dl className="grid grid-cols-2 gap-3 text-sm">
              <div>
                <dt className="text-xs font-semibold uppercase text-slate-500">Driver</dt>
                <dd>{load.driver_name ?? '—'}</dd>
              </div>
              <div>
                <dt className="text-xs font-semibold uppercase text-slate-500">Truck / Trailer</dt>
                <dd>
                  {load.truck_unit ?? '—'} / {load.trailer_unit ?? '—'}
                </dd>
              </div>
              <div>
                <dt className="text-xs font-semibold uppercase text-slate-500">Rate</dt>
                <dd className="text-lg font-bold text-navy-800">{money(load.rate)}</dd>
              </div>
              <div>
                <dt className="text-xs font-semibold uppercase text-slate-500">Miles / RPM</dt>
                <dd>
                  {Number(load.miles).toLocaleString()} mi{' '}
                  {load.rate_per_mile != null && <span className="text-slate-500">(${load.rate_per_mile.toFixed(2)}/mi)</span>}
                </dd>
              </div>
            </dl>
          </Card>
        </div>
      )}

      <DocsNotes entityType="load" entityId={id!} docTypes={['Rate Confirmation', 'BOL', 'POD', 'Photo', 'Other']} />
    </div>
  )
}

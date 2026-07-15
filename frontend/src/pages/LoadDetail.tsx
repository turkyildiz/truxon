import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { Badge, Button, Card, Field, formatDateTime, Input, money, Select, Textarea } from '../components/ui'
import {
  addNote,
  changeLoadStatus,
  downloadDocument,
  getLoad,
  listActivity,
  listCustomers,
  listDocuments,
  listDrivers,
  trailersApi,
  trucksApi,
  updateLoad,
  uploadDocument,
} from '../data'
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
  const [note, setNote] = useState('')
  const [docType, setDocType] = useState('')
  const fileRef = useRef<HTMLInputElement>(null)
  const [editForm, setEditForm] = useState<Record<string, string> | null>(null)

  const { data: load } = useQuery({ queryKey: ['load', id], queryFn: () => getLoad(id!) })
  const { data: docs = [] } = useQuery({ queryKey: ['docs', id], queryFn: () => listDocuments('load', id!) })
  const { data: activity = [] } = useQuery({ queryKey: ['activity', id], queryFn: () => listActivity('load', id!) })
  const { data: drivers = [] } = useQuery({ queryKey: ['drivers', ''], queryFn: () => listDrivers() })
  const { data: trucks = [] } = useQuery({ queryKey: ['trucks', ''], queryFn: () => trucksApi.list() })
  const { data: trailers = [] } = useQuery({ queryKey: ['trailers', ''], queryFn: () => trailersApi.list() })
  const { data: customers = [] } = useQuery({ queryKey: ['customers', ''], queryFn: () => listCustomers() })

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['load', id] })
    qc.invalidateQueries({ queryKey: ['activity', id] })
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

  const noteMutation = useMutation({
    mutationFn: () => addNote('load', id!, note),
    onSuccess: () => {
      setNote('')
      qc.invalidateQueries({ queryKey: ['activity', id] })
    },
  })

  const upload = useMutation({
    mutationFn: (file: File) => uploadDocument('load', id!, file, docType),
    onSuccess: () => {
      if (fileRef.current) fileRef.current.value = ''
      qc.invalidateQueries({ queryKey: ['docs', id] })
    },
    onError: (err) => setError(errorMessage(err)),
  })

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

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card title="Documents">
          <div className="mb-3 flex flex-wrap gap-2">
            <Select value={docType} onChange={(e) => setDocType(e.target.value)} className="!w-44">
              <option value="">Type…</option>
              {['Rate Confirmation', 'BOL', 'POD', 'Photo', 'Other'].map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
            </Select>
            <input
              ref={fileRef}
              type="file"
              onChange={(e) => e.target.files?.[0] && upload.mutate(e.target.files[0])}
              className="text-sm file:mr-3 file:rounded-lg file:border-0 file:bg-navy-700 file:px-4 file:py-2.5 file:text-sm file:font-medium file:text-white hover:file:bg-navy-800"
            />
          </div>
          {docs.length === 0 ? (
            <p className="text-sm text-slate-500">No documents uploaded.</p>
          ) : (
            <ul className="divide-y divide-slate-100 text-sm">
              {docs.map((d) => (
                <li key={d.id} className="flex items-center justify-between py-2">
                  <div>
                    <button onClick={() => downloadDocument(d)} className="font-medium text-navy-600 hover:underline">
                      {d.filename}
                    </button>
                    <span className="ml-2 text-xs text-slate-400">
                      {d.doc_type && `${d.doc_type} · `}
                      {(d.size_bytes / 1024).toFixed(0)} KB
                    </span>
                  </div>
                  <span className="text-xs text-slate-400">{formatDateTime(d.uploaded_at)}</span>
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card title="Notes & Activity">
          <div className="mb-3 flex gap-2">
            <Input
              placeholder="Add a note…"
              value={note}
              onChange={(e) => setNote(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && note && noteMutation.mutate()}
            />
            <Button onClick={() => noteMutation.mutate()} disabled={!note || noteMutation.isPending}>
              Add
            </Button>
          </div>
          <ul className="max-h-80 space-y-2 overflow-y-auto text-sm">
            {activity.map((a) => (
              <li key={a.id} className={`rounded-lg p-2.5 ${a.action === 'note' ? 'bg-amber-50' : 'bg-slate-50'}`}>
                <div className="flex justify-between text-xs text-slate-500">
                  <span className="font-semibold">
                    {a.action === 'note' ? '📝 note' : a.action.replace('_', ' ')} — {a.user_name ?? 'system'}
                  </span>
                  <span>{formatDateTime(a.created_at)}</span>
                </div>
                {a.detail && <div className="mt-1">{a.detail}</div>}
              </li>
            ))}
          </ul>
        </Card>
      </div>
    </div>
  )
}

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import ResourcePage from '../components/ResourcePage'
import { Badge, formatDate, money } from '../components/ui'
import { listEquipmentConflicts, resolveEquipmentConflict, trailersApi, trucksApi } from '../data'
import type { Equipment } from '../types'

const FIELD_LABEL: Record<string, string> = {
  vin: 'VIN', plate_number: 'Plate number', plate_expiry: 'Plate expiration',
  make: 'Make', model: 'Model', year: 'Year',
}

/** Admin review: registration/title values that disagree with what's on file.
 *  Forest never overwrites — the owner keeps the record value or accepts the doc. */
function EnrichmentConflicts({ entityType }: { entityType: 'truck' | 'trailer' }) {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['equipment-conflicts'], queryFn: listEquipmentConflicts, staleTime: 30_000 })
  const [busy, setBusy] = useState<number | null>(null)
  const resolve = useMutation({
    mutationFn: ({ logId, action }: { logId: number; action: 'keep' | 'accept' }) => resolveEquipmentConflict(logId, action),
    onMutate: (v) => setBusy(v.logId),
    onSettled: () => {
      setBusy(null)
      qc.invalidateQueries({ queryKey: ['equipment-conflicts'] })
      qc.invalidateQueries({ queryKey: [entityType === 'truck' ? 'trucks' : 'trailers'] })
    },
  })
  const rows = (q.data ?? []).filter((c) => c.equipment_type === entityType)
  if (rows.length === 0) return null
  return (
    <div className="mb-4 rounded-xl border border-amber-500/40 bg-amber-500/10 p-4">
      <div className="mb-2 text-sm font-semibold text-amber-700 dark:text-amber-300">
        ⚠️ {rows.length} registration detail{rows.length === 1 ? '' : 's'} disagree with what's on file — Forest left the record unchanged for you to decide
      </div>
      <div className="space-y-2">
        {rows.map((c) => (
          <div key={c.log_id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-1 px-3 py-2 text-sm">
            <div className="min-w-0">
              <span className="font-medium">{entityType === 'truck' ? 'Truck' : 'Trailer'} #{c.unit_number ?? '?'}</span>
              <span className="text-muted"> · {FIELD_LABEL[c.field] ?? c.field}</span>
              <div className="text-xs text-muted">
                On file: <span className="font-mono text-body">{c.old_value || '—'}</span>
                {'  →  '}document says: <span className="font-mono text-body">{c.new_value}</span>
                {c.source_filename && <span className="text-muted"> ({c.source_filename})</span>}
              </div>
            </div>
            <div className="flex shrink-0 gap-2">
              <button
                onClick={() => resolve.mutate({ logId: c.log_id, action: 'keep' })}
                disabled={busy === c.log_id}
                className="rounded-md border border-line px-2.5 py-1 text-xs font-medium text-muted hover:bg-surface-2 hover:text-body disabled:opacity-50"
                title="Keep the value already on the record"
              >
                Keep current
              </button>
              <button
                onClick={() => resolve.mutate({ logId: c.log_id, action: 'accept' })}
                disabled={busy === c.log_id}
                className="rounded-md border border-amber-500 bg-amber-500 px-2.5 py-1 text-xs font-medium text-white hover:bg-amber-600 disabled:opacity-50"
                title="Replace the record with the document's value"
              >
                Use document
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

const OWNERSHIP_OPTIONS = [
  { value: 'owned', label: 'Owned (paid off)' },
  { value: 'financed', label: 'Financed' },
  { value: 'leased', label: 'Leased' },
]

const STATUS_OPTIONS = [
  { value: 'available', label: 'Available' },
  { value: 'in_use', label: 'In Use' },
  { value: 'maintenance', label: 'Maintenance' },
  { value: 'retired', label: 'Retired' },
]

function EquipmentPage({ title, api, queryKey, entityType }: { title: string; api: typeof trucksApi; queryKey: string; entityType: 'truck' | 'trailer' }) {
  return (
    <ResourcePage<Equipment>
      title={title}
      queryKey={queryKey}
      list={api.list}
      create={api.create}
      update={api.update}
      docs={{ entityType, docTypes: ['Registration', 'Insurance', 'Inspection', 'Other'], label: (t) => `Unit ${t.unit_number}` }}
      defaultSort={{ key: 'unit', dir: 'asc' }}
      columns={[
        { header: 'Unit #', sortKey: 'unit', sortValue: (t) => t.unit_number, render: (t) => <span className="font-medium">{t.unit_number}</span> },
        { header: 'Make / Model / Year', sortKey: 'make_model_year', sortValue: (t) => [t.make, t.model, t.year].filter(Boolean).join(' '), render: (t) => [t.make, t.model, t.year].filter(Boolean).join(' ') || '—' },
        { header: 'VIN', sortKey: 'vin', sortValue: (t) => t.vin, render: (t) => t.vin || '—' },
        { header: 'Plate', sortKey: 'plate', sortValue: (t) => t.plate_number, render: (t) => (t.plate_number ? `${t.plate_number}${t.plate_expiry ? ` (exp ${formatDate(t.plate_expiry)})` : ''}` : '—') },
        { header: 'In Service', sortKey: 'in_service', sortValue: (t) => (t.in_service_date ? new Date(t.in_service_date).getTime() : null), render: (t) => formatDate(t.in_service_date) },
        { header: 'Payment /mo', sortKey: 'monthly_payment', sortValue: (t) => Number(t.monthly_payment ?? 0), render: (t) => (t.monthly_payment ? money(t.monthly_payment) : '—') },
        { header: 'Status', sortKey: 'status', sortValue: (t) => t.status, render: (t) => <Badge status={t.status} /> },
      ]}
      fields={[
        { name: 'unit_number', label: 'Unit #', required: true },
        { name: 'make', label: 'Make' },
        { name: 'model', label: 'Model' },
        { name: 'year', label: 'Year', type: 'number' },
        { name: 'vin', label: 'VIN' },
        { name: 'plate_number', label: 'Plate Number' },
        { name: 'plate_expiry', label: 'Plate Expiry', type: 'date' },
        { name: 'ownership', label: 'Ownership', type: 'select', options: OWNERSHIP_OPTIONS },
        { name: 'monthly_payment', label: 'Monthly Payment ($ — loan/lease)', type: 'number', step: '0.01' },
        { name: 'purchase_price', label: 'Purchase Price ($)', type: 'number', step: '0.01' },
        { name: 'purchase_date', label: 'Purchase Date', type: 'date' },
        { name: 'monthly_cost', label: 'Other Fixed ($/mo, excl. payment)', type: 'number', step: '0.01' },
        { name: 'in_service_date', label: 'In-Service Date', type: 'date' },
        { name: 'out_of_service_date', label: 'Out-of-Service Date', type: 'date' },
        { name: 'status', label: 'Status', type: 'select', required: true, options: STATUS_OPTIONS },
        { name: 'notes', label: 'Notes', type: 'textarea', full: true },
      ]}
      defaults={{ unit_number: '', make: '', model: '', year: '', vin: '', plate_number: '', plate_expiry: '', ownership: '', monthly_payment: '', purchase_price: '', purchase_date: '', monthly_cost: '', in_service_date: '', out_of_service_date: '', status: 'available', notes: '' }}
      toForm={(t) => ({
        unit_number: t.unit_number,
        make: t.make,
        model: t.model,
        year: t.year ?? '',
        vin: t.vin,
        plate_number: t.plate_number,
        plate_expiry: t.plate_expiry ?? '',
        ownership: t.ownership ?? '',
        monthly_payment: t.monthly_payment ?? '',
        purchase_price: t.purchase_price ?? '',
        purchase_date: t.purchase_date ?? '',
        monthly_cost: t.monthly_cost ?? '',
        in_service_date: t.in_service_date ?? '',
        out_of_service_date: t.out_of_service_date ?? '',
        status: t.status,
        notes: t.notes,
      })}
    />
  )
}

export const Trucks = () => (
  <div>
    <EnrichmentConflicts entityType="truck" />
    <EquipmentPage title="Trucks" api={trucksApi} queryKey="trucks" entityType="truck" />
  </div>
)
export const Trailers = () => (
  <div>
    <EnrichmentConflicts entityType="trailer" />
    <EquipmentPage title="Trailers" api={trailersApi} queryKey="trailers" entityType="trailer" />
  </div>
)

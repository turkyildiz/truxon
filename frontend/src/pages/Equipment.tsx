import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import ResourcePage from '../components/ResourcePage'
import { Badge, Card, formatDate, money } from '../components/ui'
import { depreciationSchedule, listEquipmentConflicts, perTruckPnl, resolveEquipmentConflict, trailersApi, trucksApi } from '../data'
import type { Equipment } from '../types'

/** Each unit judged on its own ledger: revenue on its loads minus its fuel,
 * tolls, maintenance, driver pay, and payment. ROI appears once payments are
 * entered on the truck form — no fake numbers before that. */
function TruckPnlCard() {
  const q = useQuery({ queryKey: ['per-truck-pnl'], queryFn: () => perTruckPnl(3), retry: false })
  const d = q.data
  if (q.isError || !d || d.trucks.length === 0) return null
  return (
    <Card title={`💰 Per-truck P&L — last ${d.months} months`}>
      {d.payments_entered < d.trucks_total && (
        <p className="mb-2 text-xs text-amber-700 dark:text-amber-300">
          Payments entered for {d.payments_entered}/{d.trucks_total} trucks — until the rest are on their
          forms (Edit → Monthly Payment), &ldquo;net&rdquo; overstates those units and ROI stays blank.
        </p>
      )}
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="text-left text-xs uppercase tracking-wide text-muted">
            <th className="px-2 py-1.5">Unit</th><th className="px-2 py-1.5">Loads</th>
            <th className="px-2 py-1.5">Revenue</th><th className="px-2 py-1.5">Fuel</th>
            <th className="px-2 py-1.5">Tolls</th><th className="px-2 py-1.5">Maint</th>
            <th className="px-2 py-1.5">Driver</th><th className="px-2 py-1.5">Payment</th>
            <th className="px-2 py-1.5">Net</th><th className="px-2 py-1.5">ROI</th>
          </tr></thead>
          <tbody>
            {d.trucks.map((t) => (
              <tr key={t.unit} className="border-t border-line">
                <td className="px-2 py-1.5 font-medium">{t.unit}</td>
                <td className="px-2 py-1.5">{t.loads}</td>
                <td className="px-2 py-1.5">{money(Number(t.revenue))}</td>
                <td className="px-2 py-1.5 text-muted">{Number(t.fuel) > 0 ? money(Number(t.fuel)) : '—'}</td>
                <td className="px-2 py-1.5 text-muted">{Number(t.tolls) > 0 ? money(Number(t.tolls)) : '—'}</td>
                <td className="px-2 py-1.5 text-muted">{Number(t.maintenance) > 0 ? money(Number(t.maintenance)) : '—'}</td>
                <td className="px-2 py-1.5 text-muted">{Number(t.driver_pay) > 0 ? money(Number(t.driver_pay)) : '—'}</td>
                <td className="px-2 py-1.5 text-muted">{Number(t.payment) > 0 ? money(Number(t.payment)) : '—'}</td>
                <td className={`px-2 py-1.5 font-semibold ${Number(t.net) < 0 ? 'text-red-600 dark:text-red-300' : 'text-green-700 dark:text-green-300'}`}>
                  {money(Number(t.net))}
                </td>
                <td className="px-2 py-1.5">{t.roi_x != null ? `${t.roi_x}×` : '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Card>
  )
}

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

/** Owner-view straight-line depreciation. Hidden until purchase data exists. */
function DepreciationCard() {
  const q = useQuery({ queryKey: ['depreciation'], queryFn: depreciationSchedule, retry: false })
  const d = q.data
  if (q.isError || !d || d.rows.length === 0) return null
  return (
    <Card title={`📉 Depreciation — ${money(d.monthly_depreciation_total)}/mo across ${d.entered} unit${d.entered === 1 ? '' : 's'}`}>
      <p className="mb-2 text-xs text-muted">{d.assumptions}. Enter Purchase Price + Date on the rest ({d.trucks_total - d.entered} missing) to complete the picture.</p>
      <table className="w-full text-sm">
        <thead><tr className="text-left text-xs uppercase tracking-wide text-muted">
          <th className="px-2 py-1">Unit</th><th className="px-2 py-1">Bought</th><th className="px-2 py-1">Price</th>
          <th className="px-2 py-1">$/mo</th><th className="px-2 py-1">Months in</th><th className="px-2 py-1">Book value</th>
        </tr></thead>
        <tbody>
          {d.rows.map((r) => (
            <tr key={r.unit} className="border-t border-line">
              <td className="px-2 py-1 font-medium">{r.unit}</td>
              <td className="px-2 py-1">{formatDate(r.purchase_date)}</td>
              <td className="px-2 py-1">{money(Number(r.purchase_price))}</td>
              <td className="px-2 py-1">{money(Number(r.monthly))}</td>
              <td className="px-2 py-1 text-muted">{r.months_elapsed}/60</td>
              <td className="px-2 py-1 font-semibold">{money(Number(r.book_value))}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </Card>
  )
}

export const Trucks = () => (
  <div>
    <EnrichmentConflicts entityType="truck" />
    <TruckPnlCard />
    <DepreciationCard />
    <EquipmentPage title="Trucks" api={trucksApi} queryKey="trucks" entityType="truck" />
  </div>
)
export const Trailers = () => (
  <div>
    <EnrichmentConflicts entityType="trailer" />
    <EquipmentPage title="Trailers" api={trailersApi} queryKey="trailers" entityType="trailer" />
  </div>
)

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useRef, useState } from 'react'
import ResourcePage from '../components/ResourcePage'
import { Button, Card, formatDate, LoadError, money, StatCard, Table } from '../components/ui'
import {
  createMaintenance,
  extractWorkOrderSheet,
  fleetOdometers,
  listMaintenance,
  maintenanceAlerts,
  maintenanceByTruck,
  maintenanceByVendor,
  maintenanceCpm,
  maintenanceDue,
  maintenanceSummary,
  pmProgramsApi,
  trailersApi,
  trucksApi,
  updateMaintenance,
  vendorsApi,
} from '../data'
import { errorMessage } from '../supabase'
import { SERVICE_TYPE_LABELS, type Equipment, type MaintenanceRecord, type PmProgram } from '../types'

/** Local-time YYYY-MM-DD (date inputs and range math stay in the user's zone). */
function isoDate(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
function monthStart(): string {
  const d = new Date()
  return isoDate(new Date(d.getFullYear(), d.getMonth(), 1))
}

const PILL: Record<string, string> = {
  overdue: 'bg-red-500/15 text-red-600 dark:text-red-300',
  never_serviced: 'bg-red-500/15 text-red-600 dark:text-red-300',
  due_soon: 'bg-amber-500/15 text-amber-700 dark:text-amber-300',
  ok: 'bg-green-500/15 text-green-700 dark:text-green-300',
  unknown: 'bg-slate-500/15 text-slate-500 dark:text-slate-300',
  info: 'bg-blue-500/15 text-blue-600 dark:text-blue-300',
}
const DUE_LABEL: Record<string, string> = {
  overdue: 'Overdue', never_serviced: 'No record', due_soon: 'Due soon', ok: 'OK', unknown: 'Unknown',
}
function Pill({ value, label }: { value: string; label?: string }) {
  return (
    <span className={`inline-block rounded-full px-2 py-0.5 text-xs font-semibold ${PILL[value] ?? PILL.unknown}`}>
      {label ?? value}
    </span>
  )
}

type Tab = 'overview' | 'pm' | 'costs' | 'log' | 'vendors'
const TABS: { key: Tab; label: string }[] = [
  { key: 'overview', label: 'Overview' },
  { key: 'pm', label: 'PM & Compliance' },
  { key: 'costs', label: 'Costs' },
  { key: 'log', label: 'Repair Log' },
  { key: 'vendors', label: 'Shops' },
]

export default function Maintenance() {
  const [tab, setTab] = useState<Tab>('overview')
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-bold text-body">Maintenance</h1>
      </div>
      <div className="flex flex-wrap gap-1 border-b border-line">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`-mb-px border-b-2 px-3 py-2 text-sm font-medium transition-colors ${
              tab === t.key ? 'border-brand text-brand' : 'border-transparent text-muted hover:text-body'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === 'overview' && <OverviewTab />}
      {tab === 'pm' && <PmTab />}
      {tab === 'costs' && <CostsTab />}
      {tab === 'log' && <RepairLog />}
      {tab === 'vendors' && <VendorsTab />}
    </div>
  )
}

// ---------- Overview: what needs attention ----------
function OverviewTab() {
  const start = monthStart()
  const end = isoDate(new Date())
  const alertsQ = useQuery({ queryKey: ['mx', 'alerts'], queryFn: () => maintenanceAlerts() })
  const sumQ = useQuery({ queryKey: ['mx', 'summary', start, end], queryFn: () => maintenanceSummary(start, end) })
  const reviewQ = useQuery({ queryKey: ['maintenance', 'review-count'], queryFn: async () => (await listMaintenance()).filter((m) => m.needs_review).length })
  const alerts = alertsQ.data ?? []
  const s = sumQ.data
  const reviewCount = reviewQ.data ?? 0

  return (
    <div className="space-y-4">
      {reviewCount > 0 && (
        <div className="rounded-lg bg-blue-500/10 p-3 text-sm text-blue-700 dark:text-blue-300">
          📄 {reviewCount} emailed work order{reviewCount === 1 ? '' : 's'} awaiting your review — open the <strong>Repair Log</strong> tab to confirm.
        </div>
      )}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label="Open Work Orders" value={s ? String(s.open_work_orders) : '—'} icon="🧰" color="blue" />
        <StatCard label="Units in Shop" value={s ? String(s.units_in_shop) : '—'} icon="🚧" color="amber" />
        <StatCard label="PM Compliance" value={s?.pm_compliance_pct != null ? `${s.pm_compliance_pct}%` : '—'} icon="✅" color={s?.pm_compliance_pct != null && s.pm_compliance_pct < 80 ? 'red' : 'green'} />
        <StatCard label="Maintenance (MTD)" value={s ? money(s.total_cost) : '—'} icon="💵" color="purple" />
      </div>

      <Card title={`Needs Attention${alerts.length ? ` (${alerts.length})` : ''}`}>
        {alertsQ.isError ? (
          <LoadError error={alertsQ.error} onRetry={() => alertsQ.refetch()} />
        ) : alertsQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : alerts.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">All clear — no PM, inspection, or registration items due. 🎉</p>
        ) : (
          <Table headers={['', 'Unit', 'Item', 'Detail', 'Due']}>
            {alerts.map((a, i) => (
              <tr key={i} className="hover:bg-surface-2">
                <td className="px-3 py-3"><Pill value={a.severity} label={a.severity === 'overdue' ? 'Overdue' : a.severity === 'due_soon' ? 'Soon' : 'Info'} /></td>
                <td className="px-3 py-3 font-medium">{a.unit_number ?? '—'}<span className="ml-1 text-xs text-muted">{a.equipment_type}</span></td>
                <td className="px-3 py-3">{a.label}</td>
                <td className="px-3 py-3 text-muted">{a.detail}</td>
                <td className="px-3 py-3 whitespace-nowrap">{a.due_date ? formatDate(a.due_date) : '—'}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Spend by Service (MTD)">
          {!s || s.by_service.length === 0 ? (
            <p className="py-6 text-center text-sm text-muted">No completed work this month.</p>
          ) : (
            <Table headers={['Service', 'Events', 'Cost']}>
              {s.by_service.map((r) => (
                <tr key={r.service_type}>
                  <td className="px-3 py-3">{SERVICE_TYPE_LABELS[r.service_type as keyof typeof SERVICE_TYPE_LABELS] ?? r.service_type}</td>
                  <td className="px-3 py-3">{r.events}</td>
                  <td className="px-3 py-3 font-semibold">{money(r.cost)}</td>
                </tr>
              ))}
            </Table>
          )}
        </Card>
        <Card title="Top Cost Units (MTD)">
          {!s || s.top_units.length === 0 ? (
            <p className="py-6 text-center text-sm text-muted">No completed work this month.</p>
          ) : (
            <Table headers={['Unit', 'Cost', 'CPM']}>
              {s.top_units.map((r) => (
                <tr key={r.unit_number}>
                  <td className="px-3 py-3 font-medium">{r.unit_number}</td>
                  <td className="px-3 py-3 font-semibold">{money(r.total_cost)}</td>
                  <td className="px-3 py-3">{r.cpm != null ? `$${Number(r.cpm).toFixed(3)}` : '—'}</td>
                </tr>
              ))}
            </Table>
          )}
        </Card>
      </div>
    </div>
  )
}

// ---------- PM & Compliance board ----------
function PmTab() {
  const [onlyDue, setOnlyDue] = useState(true)
  const dueQ = useQuery({ queryKey: ['mx', 'due'], queryFn: () => maintenanceDue() })
  const odoQ = useQuery({ queryKey: ['mx', 'odometers'], queryFn: () => fleetOdometers() })
  const rows = (dueQ.data ?? []).filter((r) => (onlyDue ? ['overdue', 'due_soon', 'never_serviced'].includes(r.due_status) : true))

  return (
    <div className="space-y-4">
      <Card
        title="PM & Inspection Status"
        actions={
          <label className="flex items-center gap-2 text-sm text-muted">
            <input type="checkbox" checked={onlyDue} onChange={(e) => setOnlyDue(e.target.checked)} className="h-4 w-4" />
            Due only
          </label>
        }
      >
        {dueQ.isError ? (
          <LoadError error={dueQ.error} onRetry={() => dueQ.refetch()} />
        ) : dueQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : rows.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">{onlyDue ? 'Nothing due. 🎉' : 'No programs configured.'}</p>
        ) : (
          <Table headers={['Unit', 'Program', 'Last Service', 'Current Odo', 'Miles Left', 'Days Left', 'Status']}>
            {rows.map((r) => (
              <tr key={`${r.unit_id}-${r.program_id}-${r.equipment_type}`} className="hover:bg-surface-2">
                <td className="px-3 py-3 font-medium">{r.unit_number}<span className="ml-1 text-xs text-muted">{r.equipment_type}</span></td>
                <td className="px-3 py-3">{r.program_name}</td>
                <td className="px-3 py-3 whitespace-nowrap">{r.last_service_date ? formatDate(r.last_service_date) : '—'}</td>
                <td className="px-3 py-3">{r.current_odometer != null ? Number(r.current_odometer).toLocaleString() : '—'}</td>
                <td className="px-3 py-3">{r.miles_remaining != null ? Number(r.miles_remaining).toLocaleString() : '—'}</td>
                <td className="px-3 py-3">{r.days_remaining != null ? r.days_remaining : '—'}</td>
                <td className="px-3 py-3"><Pill value={r.due_status} label={DUE_LABEL[r.due_status] ?? r.due_status} /></td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Card title="Fleet Odometers (from fuel-card readings)">
        {odoQ.isError ? (
          <LoadError error={odoQ.error} onRetry={() => odoQ.refetch()} />
        ) : odoQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : (odoQ.data ?? []).length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No trucks.</p>
        ) : (
          <Table headers={['Unit', 'Odometer', 'Last Read']}>
            {(odoQ.data ?? []).map((r) => {
              const stale = r.reading_date ? (Date.now() - new Date(r.reading_date).getTime()) / 86400000 > 14 : true
              return (
                <tr key={r.truck_id}>
                  <td className="px-3 py-3 font-medium">{r.unit_number}</td>
                  <td className="px-3 py-3">{r.odometer != null ? Number(r.odometer).toLocaleString() : '—'}</td>
                  <td className={`px-3 py-3 whitespace-nowrap ${stale ? 'text-amber-600 dark:text-amber-400' : ''}`}>
                    {r.reading_date ? formatDate(r.reading_date) : 'never'}{stale && r.reading_date ? ' (stale)' : ''}
                  </td>
                </tr>
              )
            })}
          </Table>
        )}
      </Card>

      <PmPrograms />
    </div>
  )
}

/** PM program definitions — config CRUD. */
function PmPrograms() {
  return (
    <ResourcePage<PmProgram>
      title="PM Programs"
      queryKey="pm_programs"
      searchable={false}
      addLabel="+ Program"
      list={() => pmProgramsApi.list()}
      create={(p) => pmProgramsApi.create(normalizeProgram(p))}
      update={(id, p) => pmProgramsApi.update(Number(id), normalizeProgram(p))}
      columns={[
        { header: 'Name', render: (p) => <span className="font-medium">{p.name}</span> },
        { header: 'Applies To', render: (p) => p.applies_to },
        { header: 'Every', render: (p) => [p.interval_miles ? `${Number(p.interval_miles).toLocaleString()} mi` : null, p.interval_days ? `${p.interval_days} days` : null].filter(Boolean).join(' / ') || '—' },
        { header: 'Active', render: (p) => (p.is_active ? '✓' : '—') },
      ]}
      fields={[
        { name: 'name', label: 'Name', required: true, full: true },
        { name: 'applies_to', label: 'Applies To', type: 'select', required: true, options: [{ value: 'truck', label: 'Trucks' }, { value: 'trailer', label: 'Trailers' }, { value: 'all', label: 'All' }] },
        { name: 'service_type', label: 'Service Type', type: 'select', required: true, options: Object.entries(SERVICE_TYPE_LABELS).map(([value, label]) => ({ value, label })) },
        { name: 'interval_miles', label: 'Interval (miles)', type: 'number' },
        { name: 'interval_days', label: 'Interval (days)', type: 'number' },
        { name: 'is_active', label: 'Active', type: 'checkbox' },
        { name: 'notes', label: 'Notes', type: 'textarea', full: true },
      ]}
      defaults={{ name: '', applies_to: 'truck', service_type: 'pm_service', interval_miles: '', interval_days: '', is_active: true, notes: '' }}
      toForm={(p) => ({
        name: p.name, applies_to: p.applies_to, service_type: p.service_type,
        interval_miles: p.interval_miles ?? '', interval_days: p.interval_days ?? '',
        is_active: p.is_active, notes: p.notes,
      })}
    />
  )
}
function normalizeProgram(p: Record<string, unknown>): Record<string, unknown> {
  return {
    ...p,
    interval_miles: p.interval_miles != null && p.interval_miles !== '' ? Number(p.interval_miles) : null,
    interval_days: p.interval_days != null && p.interval_days !== '' ? Number(p.interval_days) : null,
  }
}

// ---------- Costs ----------
function CostsTab() {
  const [start, setStart] = useState(monthStart())
  const [end, setEnd] = useState(isoDate(new Date()))
  const cpmQ = useQuery({ queryKey: ['mx', 'cpm', start, end], queryFn: () => maintenanceCpm(start, end) })
  const truckQ = useQuery({ queryKey: ['mx', 'by-truck', start, end], queryFn: () => maintenanceByTruck(start, end) })
  const vendorQ = useQuery({ queryKey: ['mx', 'by-vendor', start, end], queryFn: () => maintenanceByVendor(start, end) })
  const c = cpmQ.data

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <label className="text-xs font-semibold uppercase text-muted">From
          <input type="date" value={start} max={end} onChange={(e) => setStart(e.target.value)} className="mt-1 block rounded-lg border border-line bg-surface px-3 py-2 text-sm" />
        </label>
        <label className="text-xs font-semibold uppercase text-muted">To
          <input type="date" value={end} min={start} onChange={(e) => setEnd(e.target.value)} className="mt-1 block rounded-lg border border-line bg-surface px-3 py-2 text-sm" />
        </label>
      </div>

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label="Total Maintenance" value={c ? money(c.maintenance_cost) : '—'} icon="🔧" color="purple" />
        <StatCard label="Planned Share" value={c?.planned_pct != null ? `${c.planned_pct}%` : '—'} icon="📋" color="blue" footer={c ? `${money(c.reactive_cost)} reactive` : undefined} />
        <StatCard label="Maintenance CPM" value={c?.maintenance_cpm != null ? `$${Number(c.maintenance_cpm).toFixed(3)}` : '—'} icon="🛣️" color="amber" />
        <StatCard label="Tire CPM" value={c?.tire_cpm != null ? `$${Number(c.tire_cpm).toFixed(3)}` : '—'} icon="🛞" color="navy" />
      </div>

      <Card title="Cost by Truck">
        {truckQ.isError ? (
          <LoadError error={truckQ.error} onRetry={() => truckQ.refetch()} />
        ) : truckQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : (truckQ.data ?? []).length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No maintenance in this range.</p>
        ) : (
          <Table headers={['Unit', 'Events', 'Planned', 'Reactive', 'Total', 'Miles', 'CPM']}>
            {(truckQ.data ?? []).map((r) => (
              <tr key={r.truck_id} className="hover:bg-surface-2">
                <td className="px-3 py-3 font-medium">{r.unit_number}</td>
                <td className="px-3 py-3">{r.events}</td>
                <td className="px-3 py-3">{money(r.planned_cost)}</td>
                <td className="px-3 py-3">{money(r.reactive_cost)}</td>
                <td className="px-3 py-3 font-semibold">{money(r.total_cost)}</td>
                <td className="px-3 py-3">{r.window_miles != null && r.window_miles > 0 ? Number(r.window_miles).toLocaleString() : '—'}</td>
                <td className="px-3 py-3">{r.cpm != null ? `$${Number(r.cpm).toFixed(3)}` : '—'}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Card title="Spend by Shop / Vendor">
        {vendorQ.isError ? (
          <LoadError error={vendorQ.error} onRetry={() => vendorQ.refetch()} />
        ) : vendorQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : (vendorQ.data ?? []).length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No maintenance in this range.</p>
        ) : (
          <Table headers={['Vendor', 'Events', 'Planned', 'Total']}>
            {(vendorQ.data ?? []).map((r) => (
              <tr key={r.vendor}>
                <td className="px-3 py-3 font-medium">{r.vendor}</td>
                <td className="px-3 py-3">{r.events}</td>
                <td className="px-3 py-3">{money(r.planned_cost)}</td>
                <td className="px-3 py-3 font-semibold">{money(r.total_cost)}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
    </div>
  )
}

// ---------- Repair log (enriched CRUD + email/sheet intake review) ----------
/** Resolve an extracted unit number to the right equipment_type + id. */
function unitToForm(unit: unknown, trucks: Equipment[], trailers: Equipment[]): Record<string, unknown> {
  const u = String(unit ?? '').trim()
  const truck = trucks.find((t) => t.unit_number === u)
  if (truck) return { equipment_type: 'truck', truck_id: String(truck.id), trailer_id: '' }
  const trailer = trailers.find((t) => t.unit_number === u)
  if (trailer) return { equipment_type: 'trailer', truck_id: '', trailer_id: String(trailer.id) }
  return { equipment_type: 'truck', truck_id: '', trailer_id: '' }
}

function RepairLog() {
  const qc = useQueryClient()
  const { data: trucks = [] } = useQuery({ queryKey: ['trucks', ''], queryFn: () => trucksApi.list() })
  const { data: trailers = [] } = useQuery({ queryKey: ['trailers', ''], queryFn: () => trailersApi.list() })
  const reviewQ = useQuery({ queryKey: ['maintenance', 'review'], queryFn: async () => (await listMaintenance()).filter((m) => m.needs_review) })

  const fileRef = useRef<HTMLInputElement>(null)
  const [prefill, setPrefill] = useState<Record<string, unknown> | null>(null)
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState('')

  const confirmMut = useMutation({
    mutationFn: (m: MaintenanceRecord) =>
      updateMaintenance(m.id, { status: 'completed', needs_review: false, date_completed: m.date_completed ?? m.scheduled_date }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['maintenance'] }),
  })

  async function onPickSheet(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0]
    if (fileRef.current) fileRef.current.value = ''
    if (!f) return
    setBusy(true)
    setNote('')
    try {
      const r = await extractWorkOrderSheet(f)
      if (r.error || !r.fields) {
        setNote(r.error ?? 'Could not read that sheet — enter the work order manually.')
        return
      }
      const fl = r.fields
      setPrefill({
        ...unitToForm(fl.unit_number, trucks, trailers),
        service_type: fl.service_type ?? 'other',
        status: 'completed',
        is_planned: false,
        date_completed: fl.date ?? '',
        scheduled_date: '',
        odometer: fl.odometer ?? '',
        vendor_id: '',
        invoice_ref: fl.invoice_ref ?? '',
        technician_shop: fl.vendor ?? '',
        cost: fl.cost ?? '0',
        description: fl.description ?? '',
      })
    } catch (err) {
      setNote(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  const review = reviewQ.data ?? []

  return (
    <div className="space-y-4">
      {review.length > 0 && (
        <Card title={`Awaiting Review (${review.length})`}>
          <p className="mb-3 text-sm text-muted">Work orders Forest drafted from emailed shop sheets. Check the figures, edit if needed, then confirm — they don't count in your maintenance numbers until you do.</p>
          <Table headers={['Unit', 'Service', 'Shop', 'Cost', 'Description', '']}>
            {review.map((m) => (
              <tr key={m.id} className="hover:bg-surface-2">
                <td className="px-3 py-3 font-medium">{m.equipment_unit ?? '—'}</td>
                <td className="px-3 py-3">{SERVICE_TYPE_LABELS[m.service_type] ?? m.service_type}</td>
                <td className="px-3 py-3">{m.technician_shop || '—'}</td>
                <td className="px-3 py-3 font-semibold">{money(m.cost)}</td>
                <td className="px-3 py-3"><span className="line-clamp-2 max-w-xs">{m.description}</span></td>
                <td className="px-3 py-3 text-right">
                  <Button variant="secondary" disabled={confirmMut.isPending} onClick={() => confirmMut.mutate(m)}>Confirm</Button>
                </td>
              </tr>
            ))}
          </Table>
        </Card>
      )}

      <div className="flex flex-wrap items-center justify-end gap-2">
        <input ref={fileRef} type="file" accept=".pdf,image/*" className="hidden" onChange={onPickSheet} />
        <Button variant="secondary" disabled={busy} onClick={() => fileRef.current?.click()}>{busy ? 'Reading…' : '📄 Add from sheet'}</Button>
      </div>
      {note && <p className="rounded-lg bg-amber-500/10 p-3 text-sm text-amber-700 dark:text-amber-300">{note}</p>}

      <ResourcePage<MaintenanceRecord>
        title="Repair Log"
        queryKey="maintenance"
        list={() => listMaintenance()}
        create={(payload) => createMaintenance(normalize(payload))}
        update={(id, payload) => updateMaintenance(Number(id), normalize(payload))}
        searchable={false}
        addLabel="+ Log Work"
        prefill={prefill}
        onPrefillConsumed={() => setPrefill(null)}
        fieldOptionsLoader={async () => {
          const vendors = await vendorsApi.list()
          return { vendor_id: vendors.map((v) => ({ value: String(v.id), label: v.name })) }
        }}
      docs={{ entityType: 'maintenance', docTypes: ['Receipt', 'Invoice', 'Photo', 'Other'], label: (m) => `${m.equipment_unit ?? 'repair'} — ${m.description.slice(0, 40)}` }}
      columns={[
        { header: 'Date', render: (m) => formatDate(m.date_completed ?? m.scheduled_date) },
        { header: 'Equipment', render: (m) => <span className="font-medium">{m.equipment_unit ?? '—'}</span> },
        { header: 'Service', render: (m) => SERVICE_TYPE_LABELS[m.service_type] ?? m.service_type },
        { header: 'Status', render: (m) => <Pill value={m.status === 'completed' ? 'ok' : m.status === 'cancelled' ? 'unknown' : 'info'} label={m.status} /> },
        { header: 'Plan', render: (m) => (m.is_planned ? 'Planned' : 'Reactive') },
        { header: 'Cost', render: (m) => money(m.cost) },
        { header: 'Src', render: (m) => (m.needs_review ? <Pill value="due_soon" label="review" /> : m.source === 'email' ? <span className="text-xs text-muted">email</span> : null) },
      ]}
      fields={[
        { name: 'equipment_type', label: 'Equipment Type', type: 'select', required: true, options: [{ value: 'truck', label: 'Truck' }, { value: 'trailer', label: 'Trailer' }] },
        { name: 'truck_id', label: 'Truck', type: 'select', showIf: (f) => f.equipment_type === 'truck', options: trucks.map((t) => ({ value: String(t.id), label: t.unit_number })) },
        { name: 'trailer_id', label: 'Trailer', type: 'select', showIf: (f) => f.equipment_type === 'trailer', options: trailers.map((t) => ({ value: String(t.id), label: t.unit_number })) },
        { name: 'service_type', label: 'Service Type', type: 'select', required: true, options: Object.entries(SERVICE_TYPE_LABELS).map(([value, label]) => ({ value, label })) },
        { name: 'status', label: 'Status', type: 'select', required: true, options: [{ value: 'completed', label: 'Completed' }, { value: 'scheduled', label: 'Scheduled' }, { value: 'in_progress', label: 'In progress' }, { value: 'cancelled', label: 'Cancelled' }] },
        { name: 'is_planned', label: 'Planned (PM, not a breakdown)', type: 'checkbox' },
        { name: 'date_completed', label: 'Date Completed', type: 'date', showIf: (f) => f.status === 'completed' },
        { name: 'scheduled_date', label: 'Scheduled Date', type: 'date', showIf: (f) => f.status !== 'completed' },
        { name: 'odometer', label: 'Odometer (miles)', type: 'number' },
        { name: 'vendor_id', label: 'Shop / Vendor', type: 'select' },
        { name: 'invoice_ref', label: 'Shop Invoice #' },
        { name: 'technician_shop', label: 'Shop (free text, if not listed)' },
        { name: 'cost', label: 'Cost ($)', type: 'number', step: '0.01' },
        { name: 'description', label: 'Description of Work', type: 'textarea', full: true },
      ]}
      defaults={{ equipment_type: 'truck', truck_id: '', trailer_id: '', service_type: 'pm_service', status: 'completed', is_planned: false, date_completed: '', scheduled_date: '', odometer: '', vendor_id: '', invoice_ref: '', technician_shop: '', cost: '0', description: '' }}
      toForm={(m) => ({
        equipment_type: m.equipment_type,
        truck_id: m.truck_id ? String(m.truck_id) : '',
        trailer_id: m.trailer_id ? String(m.trailer_id) : '',
        service_type: m.service_type,
        status: m.status,
        is_planned: m.is_planned,
        date_completed: m.date_completed ?? '',
        scheduled_date: m.scheduled_date ?? '',
        odometer: m.odometer ?? '',
        vendor_id: m.vendor_id ? String(m.vendor_id) : '',
        invoice_ref: m.invoice_ref,
        technician_shop: m.technician_shop,
        cost: m.cost,
        description: m.description,
      })}
      />
    </div>
  )
}

/** Only the id matching equipment_type is sent; other ids → null; coerce numerics. */
function normalize(payload: Record<string, unknown>): Record<string, unknown> {
  const isTruck = payload.equipment_type === 'truck'
  return {
    ...payload,
    truck_id: isTruck && payload.truck_id ? Number(payload.truck_id) : null,
    trailer_id: !isTruck && payload.trailer_id ? Number(payload.trailer_id) : null,
    vendor_id: payload.vendor_id ? Number(payload.vendor_id) : null,
    odometer: payload.odometer != null && payload.odometer !== '' ? Number(payload.odometer) : null,
    cost: payload.cost != null && payload.cost !== '' ? Number(payload.cost) : 0,
  }
}

// ---------- Shops / vendors ----------
function VendorsTab() {
  return (
    <ResourcePage
      title="Shops"
      queryKey="maintenance_vendors"
      searchable={false}
      addLabel="+ Shop"
      list={() => vendorsApi.list()}
      create={(p) => vendorsApi.create(p)}
      update={(id, p) => vendorsApi.update(Number(id), p)}
      columns={[
        { header: 'Name', render: (v) => <span className="font-medium">{v.name}</span> },
        { header: 'Specialty', render: (v) => v.specialty || '—' },
        { header: 'Location', render: (v) => [v.city, v.state].filter(Boolean).join(', ') || '—' },
        { header: 'Phone', render: (v) => v.phone || '—' },
        { header: 'Active', render: (v) => (v.is_active ? '✓' : '—') },
      ]}
      fields={[
        { name: 'name', label: 'Name', required: true, full: true },
        { name: 'specialty', label: 'Specialty (tires, engine, mobile…)' },
        { name: 'phone', label: 'Phone' },
        { name: 'city', label: 'City' },
        { name: 'state', label: 'State' },
        { name: 'is_active', label: 'Active', type: 'checkbox' },
        { name: 'notes', label: 'Notes', type: 'textarea', full: true },
      ]}
      defaults={{ name: '', specialty: '', phone: '', city: '', state: '', is_active: true, notes: '' }}
      toForm={(v) => ({ name: v.name, specialty: v.specialty, phone: v.phone, city: v.city, state: v.state, is_active: v.is_active, notes: v.notes })}
    />
  )
}

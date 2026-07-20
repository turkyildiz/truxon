import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Badge, Button, Card, formatDateTime, Input, LoadError, money, Select } from '../components/ui'
import { listCustomers, listDrivers, listLoads, listMissingPods } from '../data'
import { LOAD_STATUSES } from '../types'

const ALL_STATUSES = [...LOAD_STATUSES, 'cancelled' as const]

/** Delivered/billed loads with no POD on file — money that can stall. */
function MissingPodsBanner() {
  const [open, setOpen] = useState(false)
  const q = useQuery({ queryKey: ['missing-pods', 45], queryFn: () => listMissingPods(45), staleTime: 60_000 })
  const rows = q.data ?? []
  if (rows.length === 0) return null
  return (
    <div className="rounded-xl border border-amber-500/40 bg-amber-500/10 px-4 py-3">
      <button onClick={() => setOpen((v) => !v)} className="flex w-full items-center justify-between text-left">
        <span className="text-sm font-semibold text-amber-700 dark:text-amber-300">
          📄 {rows.length} delivered load{rows.length === 1 ? '' : 's'} missing a POD (last 45 days) — brokers won't pay without it
        </span>
        <span className="text-xs text-amber-700 dark:text-amber-300">{open ? 'hide' : 'show'}</span>
      </button>
      {open && (
        <div className="mt-2 max-h-56 space-y-1 overflow-y-auto">
          {rows.slice(0, 60).map((r) => (
            <Link key={r.load_id} to={`/loads/${r.load_id}`} className="flex items-center justify-between rounded px-2 py-1 text-sm hover:bg-amber-500/10">
              <span className="font-medium text-brand">#{r.load_number}</span>
              <span className="truncate px-2 text-muted">{r.customer ?? '—'}</span>
              <span className="text-xs capitalize text-muted">{r.status}</span>
            </Link>
          ))}
        </div>
      )}
    </div>
  )
}

export default function Loads() {
  const navigate = useNavigate()
  const [q, setQ] = useState('')
  // Status toggles (crew feedback): one switch per status, multi-select;
  // the landing view opens with In Transit on. All off = show everything.
  const [statuses, setStatuses] = useState<Set<string>>(() => new Set(['in_transit']))
  const toggleStatus = (s: string) =>
    setStatuses((prev) => {
      const next = new Set(prev)
      if (next.has(s)) next.delete(s)
      else next.add(s)
      return next
    })
  const statusList = [...statuses].sort()
  const [awaitingOnly, setAwaitingOnly] = useState(false)
  const [customerId, setCustomerId] = useState('')
  const [driverId, setDriverId] = useState('')
  const [dateFrom, setDateFrom] = useState('')
  const [dateTo, setDateTo] = useState('')

  // Include inactive customers — old loads still need to be filterable by them.
  const { data: customers = [] } = useQuery({ queryKey: ['customers-all', ''], queryFn: () => listCustomers(undefined, { includeInactive: true }) })
  const { data: drivers = [] } = useQuery({ queryKey: ['drivers', ''], queryFn: () => listDrivers() })
  const loadsQ = useQuery({
    queryKey: ['loads', q, statusList.join(','), awaitingOnly, customerId, driverId, dateFrom, dateTo],
    queryFn: () => listLoads({ q, statuses: statusList, awaiting_paperwork: awaitingOnly, customer_id: customerId, driver_id: driverId, date_from: dateFrom, date_to: dateTo }),
  })
  const { data: loads = [], isLoading } = loadsQ

  return (
    <div className="space-y-4">
    <MissingPodsBanner />
    <Card title="Loads" actions={<Button onClick={() => navigate('/dispatch')}>+ New Load</Button>}>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        {ALL_STATUSES.map((s) => {
          const on = statuses.has(s)
          return (
            <button
              key={s}
              onClick={() => toggleStatus(s)}
              className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium capitalize transition-colors ${
                on ? 'border-brand bg-brand text-white' : 'border-line text-muted hover:bg-surface-2 hover:text-body'
              }`}
              title={on ? 'Hide these loads' : 'Show these loads'}
            >
              <span className={`h-1.5 w-1.5 rounded-full ${on ? 'bg-white' : 'bg-current'}`} />
              {s.replace('_', ' ')}
            </button>
          )
        })}
        {statuses.size > 0 && (
          <button onClick={() => setStatuses(new Set())} className="px-2 py-1.5 text-sm text-muted hover:text-body" title="Show all statuses">
            Show all
          </button>
        )}
        <span className="mx-1 h-5 w-px self-center bg-line" />
        <button
          onClick={() => setAwaitingOnly((v) => !v)}
          className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium transition-colors ${
            awaitingOnly ? 'border-amber-500 bg-amber-500 text-white' : 'border-line text-muted hover:bg-surface-2 hover:text-body'
          }`}
          title="Show only loads awaiting final paperwork"
        >
          📄 Awaiting paperwork
        </button>
      </div>
      <div className="mb-4 flex flex-wrap gap-3">
        <Input placeholder="Search load #, broker #, address…" value={q} onChange={(e) => setQ(e.target.value)} className="w-full sm:w-64" />
        <Select value={customerId} onChange={(e) => setCustomerId(e.target.value)} className="w-full sm:w-56">
          <option value="">All customers</option>
          {customers.map((c) => (
            <option key={c.id} value={c.id}>
              {c.company_name}
            </option>
          ))}
        </Select>
        <Select value={driverId} onChange={(e) => setDriverId(e.target.value)} className="w-full sm:w-48">
          <option value="">All drivers</option>
          {drivers.map((d) => (
            <option key={d.id} value={d.id}>
              {d.full_name}
            </option>
          ))}
        </Select>
        <div className="flex items-center gap-2">
          <Input type="date" title="Pickup from" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} className="!w-40" />
          <span className="text-muted">–</span>
          <Input type="date" title="Pickup to" value={dateTo} onChange={(e) => setDateTo(e.target.value)} className="!w-40" />
        </div>
      </div>

      {isLoading ? (
        <p className="py-8 text-center text-muted">Loading…</p>
      ) : loadsQ.isError ? (
        <LoadError error={loadsQ.error} onRetry={() => loadsQ.refetch()} />
      ) : loads.length === 0 ? (
        <p className="py-8 text-center text-muted">No loads match.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-line text-left">
                {['Load #', 'Customer', 'Pickup', 'Delivery', 'Driver', 'Rate', 'RPM', 'Status'].map((h) => (
                  <th key={h} className="px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-muted">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {loads.map((load) => (
                <tr key={load.id} className="cursor-pointer hover:bg-surface-2" onClick={() => navigate(`/loads/${load.id}`)}>
                  <td className="px-3 py-3 font-medium text-brand">
                    <Link to={`/loads/${load.id}`} onClick={(e) => e.stopPropagation()}>
                      {load.load_number}
                    </Link>
                    {load.reference_number && <div className="text-xs font-normal text-muted">{load.reference_number}</div>}
                  </td>
                  <td className="px-3 py-3">{load.customer_name}</td>
                  <td className="px-3 py-3">
                    <div className="max-w-45 truncate">{load.pickup_address || '—'}</div>
                    <div className="text-xs text-muted">{formatDateTime(load.pickup_time)}</div>
                  </td>
                  <td className="px-3 py-3">
                    <div className="max-w-45 truncate">{load.delivery_address || '—'}</div>
                    <div className="text-xs text-muted">{formatDateTime(load.delivery_time)}</div>
                  </td>
                  <td className="px-3 py-3">{load.driver_name ?? '—'}</td>
                  <td className="px-3 py-3">{money(load.rate)}</td>
                  <td className="px-3 py-3">{load.rate_per_mile != null ? `$${load.rate_per_mile.toFixed(2)}` : '—'}</td>
                  <td className="px-3 py-3">
                    <div className="flex flex-col items-start gap-1">
                      <Badge status={load.status} />
                      {load.awaiting_paperwork && (
                        <span className="inline-flex items-center gap-1 rounded-full bg-amber-500/15 px-2 py-0.5 text-xs font-semibold text-amber-600 dark:text-amber-300" title="Booked — final paperwork not received yet">
                          📄 Awaiting paperwork
                        </span>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
    </div>
  )
}

import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Badge, Button, Card, formatDateTime, Input, LoadError, money, Select } from '../components/ui'
import { listCustomers, listDrivers, listLoads } from '../data'
import { LOAD_STATUSES } from '../types'

const ALL_STATUSES = [...LOAD_STATUSES, 'cancelled' as const]

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
  const [customerId, setCustomerId] = useState('')
  const [driverId, setDriverId] = useState('')
  const [dateFrom, setDateFrom] = useState('')
  const [dateTo, setDateTo] = useState('')

  // Include inactive customers — old loads still need to be filterable by them.
  const { data: customers = [] } = useQuery({ queryKey: ['customers-all', ''], queryFn: () => listCustomers(undefined, { includeInactive: true }) })
  const { data: drivers = [] } = useQuery({ queryKey: ['drivers', ''], queryFn: () => listDrivers() })
  const loadsQ = useQuery({
    queryKey: ['loads', q, statusList.join(','), customerId, driverId, dateFrom, dateTo],
    queryFn: () => listLoads({ q, statuses: statusList, customer_id: customerId, driver_id: driverId, date_from: dateFrom, date_to: dateTo }),
  })
  const { data: loads = [], isLoading } = loadsQ

  return (
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
                    <Badge status={load.status} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}

import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Badge, Button, Card, formatDateTime, Input, LoadError, money, Select } from '../components/ui'
import { listCustomers, listDrivers, listLoads } from '../data'
import { LOAD_STATUSES } from '../types'

export default function Loads() {
  const navigate = useNavigate()
  const [q, setQ] = useState('')
  const [status, setStatus] = useState('')
  const [customerId, setCustomerId] = useState('')
  const [driverId, setDriverId] = useState('')
  const [dateFrom, setDateFrom] = useState('')
  const [dateTo, setDateTo] = useState('')

  // Include inactive customers — old loads still need to be filterable by them.
  const { data: customers = [] } = useQuery({ queryKey: ['customers-all', ''], queryFn: () => listCustomers(undefined, { includeInactive: true }) })
  const { data: drivers = [] } = useQuery({ queryKey: ['drivers', ''], queryFn: () => listDrivers() })
  const loadsQ = useQuery({
    queryKey: ['loads', q, status, customerId, driverId, dateFrom, dateTo],
    queryFn: () => listLoads({ q, status, customer_id: customerId, driver_id: driverId, date_from: dateFrom, date_to: dateTo }),
  })
  const { data: loads = [], isLoading } = loadsQ

  return (
    <Card title="Loads" actions={<Button onClick={() => navigate('/dispatch')}>+ New Load</Button>}>
      <div className="mb-4 flex flex-wrap gap-3">
        <Input placeholder="Search load #, broker #, address…" value={q} onChange={(e) => setQ(e.target.value)} className="w-full sm:w-64" />
        <Select value={status} onChange={(e) => setStatus(e.target.value)} className="w-full sm:w-44">
          <option value="">All statuses</option>
          {LOAD_STATUSES.map((s) => (
            <option key={s} value={s}>
              {s.replace('_', ' ')}
            </option>
          ))}
        </Select>
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

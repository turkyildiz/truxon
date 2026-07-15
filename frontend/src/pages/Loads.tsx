import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { api } from '../api'
import { Badge, Button, Card, formatDateTime, Input, money, Select } from '../components/ui'
import { LOAD_STATUSES, type Customer, type Load } from '../types'

export default function Loads() {
  const navigate = useNavigate()
  const [q, setQ] = useState('')
  const [status, setStatus] = useState('')
  const [customerId, setCustomerId] = useState('')

  const { data: customers = [] } = useQuery({
    queryKey: ['/customers'],
    queryFn: () => api.get<Customer[]>('/customers').then((r) => r.data),
  })

  const { data: loads = [], isLoading } = useQuery({
    queryKey: ['/loads', q, status, customerId],
    queryFn: () =>
      api
        .get<Load[]>('/loads', {
          params: {
            ...(q ? { q } : {}),
            ...(status ? { status } : {}),
            ...(customerId ? { customer_id: customerId } : {}),
          },
        })
        .then((r) => r.data),
  })

  return (
    <Card
      title="Loads"
      actions={<Button onClick={() => navigate('/dispatch')}>+ New Load</Button>}
    >
      <div className="mb-4 flex flex-wrap gap-3">
        <Input placeholder="Search load #, address…" value={q} onChange={(e) => setQ(e.target.value)} className="w-full sm:w-64" />
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
      </div>

      {isLoading ? (
        <p className="py-8 text-center text-slate-500">Loading…</p>
      ) : loads.length === 0 ? (
        <p className="py-8 text-center text-slate-500">No loads match.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-slate-200 text-left">
                {['Load #', 'Customer', 'Pickup', 'Delivery', 'Driver', 'Rate', 'RPM', 'Status'].map((h) => (
                  <th key={h} className="px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-slate-500">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {loads.map((load) => (
                <tr key={load.id} className="cursor-pointer hover:bg-slate-50" onClick={() => navigate(`/loads/${load.id}`)}>
                  <td className="px-3 py-3 font-medium text-navy-700">
                    <Link to={`/loads/${load.id}`} onClick={(e) => e.stopPropagation()}>
                      {load.load_number}
                    </Link>
                  </td>
                  <td className="px-3 py-3">{load.customer_name}</td>
                  <td className="px-3 py-3">
                    <div className="max-w-45 truncate">{load.pickup_address || '—'}</div>
                    <div className="text-xs text-slate-500">{formatDateTime(load.pickup_time)}</div>
                  </td>
                  <td className="px-3 py-3">
                    <div className="max-w-45 truncate">{load.delivery_address || '—'}</div>
                    <div className="text-xs text-slate-500">{formatDateTime(load.delivery_time)}</div>
                  </td>
                  <td className="px-3 py-3">{load.driver_name ?? '—'}</td>
                  <td className="px-3 py-3">{money(load.rate)}</td>
                  <td className="px-3 py-3">{load.rate_per_mile ? `$${load.rate_per_mile}` : '—'}</td>
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

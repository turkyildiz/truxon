import { useQuery } from '@tanstack/react-query'
import { Link, useNavigate } from 'react-router-dom'
import { Bar, BarChart, Cell, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { useAuth } from '../auth'
import { Badge, Button, Card, formatDate, formatDateTime, LoadError, money } from '../components/ui'
import { dashboardSummary } from '../data'

/** Roles allowed the company-wide dashboard (mirrors the dashboard_summary
 * RPC gate — driver/maintenance must not see fleet revenue or dispatch data). */
const DASHBOARD_ROLES = ['admin', 'dispatcher', 'accountant']

const STATUS_CHART_COLORS: Record<string, string> = {
  pending: '#94a3b8',
  assigned: '#3b82f6',
  in_transit: '#f59e0b',
  delivered: '#14b8a6',
  completed: '#22c55e',
  billed: '#a855f7',
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="rounded-xl bg-white p-5 shadow-sm">
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">{label}</div>
      <div className={`mt-1 text-2xl font-bold ${accent ? 'text-navy-700' : ''}`}>{value}</div>
    </div>
  )
}

export default function Dashboard() {
  const navigate = useNavigate()
  const { user } = useAuth()
  const canView = DASHBOARD_ROLES.includes(user?.role ?? '')
  const summaryQ = useQuery({
    queryKey: ['dashboard'],
    queryFn: dashboardSummary,
    refetchInterval: 60_000,
    enabled: canView,
  })
  const { data, isLoading } = summaryQ

  if (!canView) {
    return (
      <Card title={`Welcome, ${user?.full_name || user?.username}`}>
        <p className="text-sm text-slate-600">
          You're signed in as <span className="font-medium capitalize">{user?.role}</span>. Use the menu to reach your modules — company-wide
          dashboards are limited to office staff.
        </p>
      </Card>
    )
  }
  if (summaryQ.isError) return <LoadError error={summaryQ.error} onRetry={() => summaryQ.refetch()} />
  if (isLoading || !data) return <p className="py-8 text-center text-slate-500">Loading dashboard…</p>

  const pieData = Object.entries(data.status_counts)
    .filter(([, v]) => v > 0)
    .map(([name, value]) => ({ name: name.replace('_', ' '), key: name, value }))

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-bold text-navy-800">Dashboard</h1>
        <div className="flex gap-2">
          <Button onClick={() => navigate('/dispatch')}>+ New Load</Button>
          <Button variant="secondary" onClick={() => navigate('/reports')}>
            Weekly Report
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-6">
        <Stat label="Week Revenue" value={money(data.week_revenue)} accent />
        <Stat label="Week Miles" value={Number(data.week_miles).toLocaleString()} />
        <Stat label="Week Loads" value={String(data.week_loads)} />
        <Stat label="Avg Rate/Mile" value={data.week_avg_rate_per_mile != null ? `$${Number(data.week_avg_rate_per_mile).toFixed(2)}` : '—'} />
        <Stat label="Trucks Available" value={String(data.available_trucks)} />
        <Stat label="Active Drivers" value={String(data.active_drivers)} />
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card title="Revenue This Week (Mon–Sun)">
          <ResponsiveContainer width="100%" height={240}>
            <BarChart data={data.revenue_by_day}>
              <XAxis dataKey="day" tick={{ fontSize: 12 }} />
              <YAxis tick={{ fontSize: 12 }} tickFormatter={(v) => `$${(v / 1000).toFixed(0)}k`} />
              <Tooltip formatter={(v) => money(Number(v))} />
              <Bar dataKey="revenue" fill="#1e3a5f" radius={[6, 6, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </Card>
        <Card title="Load Status Distribution">
          {pieData.length === 0 ? (
            <p className="py-16 text-center text-sm text-slate-500">No loads yet.</p>
          ) : (
            <ResponsiveContainer width="100%" height={240}>
              <PieChart>
                <Pie data={pieData} dataKey="value" nameKey="name" innerRadius={55} outerRadius={90} label={(e) => `${e.name} (${e.value})`}>
                  {pieData.map((entry) => (
                    <Cell key={entry.key} fill={STATUS_CHART_COLORS[entry.key] ?? '#94a3b8'} />
                  ))}
                </Pie>
                <Tooltip />
              </PieChart>
            </ResponsiveContainer>
          )}
        </Card>
      </div>

      {data.expiring_licenses.length > 0 && (
        <Card title="⚠️ Licenses Expiring Within 30 Days">
          <ul className="divide-y divide-slate-100 text-sm">
            {data.expiring_licenses.map((d) => (
              <li key={d.id} className="flex justify-between py-2">
                <span className="font-medium">{d.full_name}</span>
                <span className="text-red-600">{formatDate(d.license_expiration)}</span>
              </li>
            ))}
          </ul>
        </Card>
      )}

      <Card title="Active Loads">
        {data.active_loads.length === 0 ? (
          <p className="py-6 text-center text-sm text-slate-500">No loads currently assigned or in transit.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 text-left">
                  {['Load #', 'Customer', 'Route', 'Driver', 'Pickup', 'Status'].map((h) => (
                    <th key={h} className="px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-slate-500">
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {data.active_loads.map((l) => (
                  <tr key={l.id} className="cursor-pointer hover:bg-slate-50" onClick={() => navigate(`/loads/${l.id}`)}>
                    <td className="px-3 py-3 font-medium text-navy-700">
                      <Link to={`/loads/${l.id}`} onClick={(e) => e.stopPropagation()}>
                        {l.load_number}
                      </Link>
                    </td>
                    <td className="px-3 py-3">{l.customer_name}</td>
                    <td className="max-w-60 truncate px-3 py-3">
                      {l.pickup_address?.split(',')[0]} → {l.delivery_address?.split(',')[0]}
                    </td>
                    <td className="px-3 py-3">{l.driver_name ?? '—'}</td>
                    <td className="px-3 py-3 text-slate-500">{formatDateTime(l.pickup_time)}</td>
                    <td className="px-3 py-3">
                      <Badge status={l.status} />
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

import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Area, AreaChart, Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { useAuth } from '../auth'
import { Badge, Button, Card, formatDate, formatDateTime, LoadError, money } from '../components/ui'
import { dashboardSummary } from '../data'
import type { TrendPoint } from '../types'

/** Roles allowed the company-wide dashboard (mirrors the dashboard_summary
 * RPC gate — driver/maintenance must not see fleet revenue or dispatch data). */
const DASHBOARD_ROLES = ['admin', 'dispatcher', 'accountant']

const STATUS_PILL_COLORS: Record<string, string> = {
  pending: 'bg-slate-100 text-slate-600',
  assigned: 'bg-blue-100 text-blue-700',
  in_transit: 'bg-amber-100 text-amber-700',
  delivered: 'bg-teal-100 text-teal-700',
  completed: 'bg-green-100 text-green-700',
  billed: 'bg-purple-100 text-purple-700',
}

function pctChange(current: number, prev: number): number | null {
  if (!prev) return null
  return ((current - prev) / prev) * 100
}

function TrendBadge({ change, vs, noDataLabel }: { change: number | null; vs: string; noDataLabel: string }) {
  if (change == null) return <span className="rounded-full bg-white/10 px-2 py-0.5 text-xs font-medium text-white/70">{noDataLabel}</span>
  return (
    <span className="rounded-full bg-white/20 px-2 py-0.5 text-xs font-semibold">
      {change >= 0 ? '+' : ''}
      {change.toFixed(1)}% {vs}
    </span>
  )
}

function KpiCard({
  label,
  value,
  icon,
  gradient,
  change,
  changeYoY,
}: {
  label: string
  value: string
  icon: string
  gradient: string
  change: number | null
  changeYoY: number | null
}) {
  return (
    <div className={`relative overflow-hidden rounded-2xl bg-gradient-to-br ${gradient} p-5 text-white shadow-md`}>
      <div className="flex items-start justify-between">
        <div className="text-sm font-semibold text-white/90">{label}</div>
        <div className="flex h-11 w-11 items-center justify-center rounded-full bg-white/20 text-xl">{icon}</div>
      </div>
      <div className="mt-1 text-3xl font-extrabold tracking-tight">{value}</div>
      <div className="mt-2 flex flex-wrap justify-end gap-1.5">
        <TrendBadge change={change} vs="vs last wk" noDataLabel="no prior week" />
        <TrendBadge change={changeYoY} vs="vs last yr" noDataLabel="no data last yr" />
      </div>
    </div>
  )
}

function PeriodSelect({ value, onChange }: { value: 'weekly' | 'monthly'; onChange: (v: 'weekly' | 'monthly') => void }) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value as 'weekly' | 'monthly')}
      className="rounded-lg border-0 bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white focus:outline-none"
    >
      <option value="weekly">Weekly</option>
      <option value="monthly">Monthly</option>
    </select>
  )
}

function LegendChip({ color, label }: { color: string; label: string }) {
  return (
    <span className="flex items-center gap-1.5 text-xs font-medium text-slate-500">
      <span className="h-2.5 w-2.5 rounded-sm" style={{ backgroundColor: color }} />
      {label}
    </span>
  )
}

/** Shortens "FirstName LastName" / long company names for bar chart ticks. */
const shortName = (n: string) => (n.length > 11 ? `${n.slice(0, 10)}…` : n)

export default function Dashboard() {
  const navigate = useNavigate()
  const { user } = useAuth()
  const canView = DASHBOARD_ROLES.includes(user?.role ?? '')
  const [period, setPeriod] = useState<'weekly' | 'monthly'>('weekly')
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

  const trend: TrendPoint[] = (period === 'weekly' ? data.trend_weekly : data.trend_monthly) ?? []
  const statusPills = Object.entries(data.status_counts).filter(([, v]) => v > 0)

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

      {/* KPI cards — this week vs last week */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <KpiCard
          label="Week Revenue"
          value={money(data.week_revenue)}
          icon="💰"
          gradient="from-blue-500 to-blue-700"
          change={pctChange(data.week_revenue, data.prev_week?.revenue ?? 0)}
          changeYoY={pctChange(data.week_revenue, data.prev_year_week?.revenue ?? 0)}
        />
        <KpiCard
          label="Week Miles"
          value={Number(data.week_miles).toLocaleString()}
          icon="🛣️"
          gradient="from-amber-400 to-orange-600"
          change={pctChange(Number(data.week_miles), Number(data.prev_week?.miles ?? 0))}
          changeYoY={pctChange(Number(data.week_miles), Number(data.prev_year_week?.miles ?? 0))}
        />
        <KpiCard
          label="Week Loads"
          value={String(data.week_loads)}
          icon="📦"
          gradient="from-emerald-400 to-green-600"
          change={pctChange(data.week_loads, data.prev_week?.loads ?? 0)}
          changeYoY={pctChange(data.week_loads, data.prev_year_week?.loads ?? 0)}
        />
        <KpiCard
          label="Avg Rate / Mile"
          value={data.week_avg_rate_per_mile != null ? `$${Number(data.week_avg_rate_per_mile).toFixed(2)}` : '—'}
          icon="📈"
          gradient="from-orange-500 to-red-600"
          change={pctChange(Number(data.week_avg_rate_per_mile ?? 0), Number(data.prev_week?.avg_rate_per_mile ?? 0))}
          changeYoY={pctChange(Number(data.week_avg_rate_per_mile ?? 0), Number(data.prev_year_week?.avg_rate_per_mile ?? 0))}
        />
      </div>

      {/* Fleet strip: availability + live load statuses */}
      <div className="flex flex-wrap items-center gap-x-6 gap-y-2 rounded-xl bg-white px-5 py-3 shadow-sm">
        <span className="text-sm font-semibold text-navy-800">
          🚛 {data.available_trucks} truck{data.available_trucks === 1 ? '' : 's'} available
        </span>
        <span className="text-sm font-semibold text-navy-800">🪪 {data.active_drivers} active drivers</span>
        <span className="ml-auto flex flex-wrap items-center gap-1.5">
          {statusPills.map(([status, n]) => (
            <span key={status} className={`rounded-full px-2.5 py-0.5 text-xs font-semibold capitalize ${STATUS_PILL_COLORS[status] ?? 'bg-slate-100 text-slate-600'}`}>
              {status.replace('_', ' ')} {n}
            </span>
          ))}
        </span>
      </div>

      {/* Revenue trend */}
      <Card title="Revenue Trend" actions={<PeriodSelect value={period} onChange={setPeriod} />}>
        <ResponsiveContainer width="100%" height={240}>
          <AreaChart data={trend}>
            <defs>
              <linearGradient id="gradRevenue" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="#3b82f6" stopOpacity={0.55} />
                <stop offset="100%" stopColor="#3b82f6" stopOpacity={0.05} />
              </linearGradient>
            </defs>
            <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
            <XAxis dataKey="label" tick={{ fontSize: 12 }} tickLine={false} axisLine={false} />
            <YAxis tick={{ fontSize: 12 }} tickLine={false} axisLine={false} tickFormatter={(v) => `$${(v / 1000).toFixed(0)}k`} />
            <Tooltip formatter={(v) => money(Number(v))} />
            <Area type="monotone" dataKey="revenue" name="Revenue" stroke="#2563eb" strokeWidth={2.5} fill="url(#gradRevenue)" />
          </AreaChart>
        </ResponsiveContainer>
      </Card>

      {/* Miles trend — loaded vs empty */}
      <Card
        title="Miles Trend"
        actions={
          <div className="flex items-center gap-4">
            <LegendChip color="#10b981" label="Total miles" />
            <LegendChip color="#f59e0b" label="Empty miles" />
            <PeriodSelect value={period} onChange={setPeriod} />
          </div>
        }
      >
        <ResponsiveContainer width="100%" height={220}>
          <AreaChart data={trend}>
            <defs>
              <linearGradient id="gradMiles" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="#10b981" stopOpacity={0.5} />
                <stop offset="100%" stopColor="#10b981" stopOpacity={0.05} />
              </linearGradient>
              <linearGradient id="gradEmpty" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="#f59e0b" stopOpacity={0.5} />
                <stop offset="100%" stopColor="#f59e0b" stopOpacity={0.05} />
              </linearGradient>
            </defs>
            <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
            <XAxis dataKey="label" tick={{ fontSize: 12 }} tickLine={false} axisLine={false} />
            <YAxis tick={{ fontSize: 12 }} tickLine={false} axisLine={false} tickFormatter={(v) => Number(v).toLocaleString()} />
            <Tooltip formatter={(v) => Number(v).toLocaleString()} />
            <Area type="monotone" dataKey="miles" name="Total miles" stroke="#059669" strokeWidth={2.5} fill="url(#gradMiles)" />
            <Area type="monotone" dataKey="empty_miles" name="Empty miles" stroke="#d97706" strokeWidth={2.5} fill="url(#gradEmpty)" />
          </AreaChart>
        </ResponsiveContainer>
      </Card>

      {/* Bottom bar panels */}
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card title="Top Customers (90 days)" actions={<LegendChip color="#10b981" label="Revenue" />}>
          {data.top_customers.length === 0 ? (
            <p className="py-16 text-center text-sm text-slate-500">No completed loads in the last 90 days.</p>
          ) : (
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={data.top_customers.map((c) => ({ ...c, short: shortName(c.name) }))}>
                <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
                <XAxis dataKey="short" tick={{ fontSize: 11 }} tickLine={false} axisLine={false} interval={0} />
                <YAxis tick={{ fontSize: 12 }} tickLine={false} axisLine={false} tickFormatter={(v) => `$${(v / 1000).toFixed(0)}k`} />
                <Tooltip formatter={(v) => money(Number(v))} labelFormatter={(_, p) => p?.[0]?.payload?.name ?? ''} />
                <Bar dataKey="revenue" name="Revenue" fill="#10b981" radius={[6, 6, 0, 0]} maxBarSize={42} />
              </BarChart>
            </ResponsiveContainer>
          )}
        </Card>
        <Card title="Driver Performance (30 days)" actions={<LegendChip color="#f59e0b" label="Miles" />}>
          {data.driver_perf.length === 0 ? (
            <p className="py-16 text-center text-sm text-slate-500">No completed loads in the last 30 days.</p>
          ) : (
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={data.driver_perf.map((d) => ({ ...d, short: shortName(d.name) }))}>
                <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
                <XAxis dataKey="short" tick={{ fontSize: 11 }} tickLine={false} axisLine={false} interval={0} />
                <YAxis tick={{ fontSize: 12 }} tickLine={false} axisLine={false} tickFormatter={(v) => Number(v).toLocaleString()} />
                <Tooltip
                  formatter={(v, name) => (name === 'Miles' ? Number(v).toLocaleString() : money(Number(v)))}
                  labelFormatter={(_, p) => p?.[0]?.payload?.name ?? ''}
                />
                <Bar dataKey="miles" name="Miles" fill="#f59e0b" radius={[6, 6, 0, 0]} maxBarSize={42} />
              </BarChart>
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

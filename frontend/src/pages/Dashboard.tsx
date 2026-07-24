import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Area, AreaChart, Bar, BarChart, ResponsiveContainer } from 'recharts'
import { useAuth } from '../auth'
import { CHART, ChartGrid, ChartTooltip, ChartXAxis, ChartYAxis, LegendChip } from '../components/charts'
import { Badge, Button, Card, cityState, formatDate, formatDateTime, LoadError, money, StatCard } from '../components/ui'
import { cashflowForecast, collectionsQueue, customerKeepFire, dashboardSummary, slowPayRisk } from '../data'
import { weekTitle } from '../lib/week'
import type { TrendPoint } from '../types'

/** Roles allowed the company-wide dashboard (mirrors the dashboard_summary
 * RPC gate — driver/maintenance must not see fleet revenue or dispatch data). */
const DASHBOARD_ROLES = ['admin', 'dispatcher', 'accountant']

const STATUS_PILL_COLORS: Record<string, string> = {
  pending: 'bg-slate-500/15 text-muted',
  assigned: 'bg-blue-500/15 text-blue-600 dark:text-blue-300',
  in_transit: 'bg-amber-500/15 text-amber-700 dark:text-amber-300',
  delivered: 'bg-teal-500/15 text-teal-600 dark:text-teal-300',
  completed: 'bg-green-500/15 text-green-700 dark:text-green-300',
  billed: 'bg-purple-500/15 text-purple-600 dark:text-purple-300',
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

/** The KPI card's week/year trend pair, passed as StatCard's footer. */
function KpiTrend({ change, changeYoY }: { change: number | null; changeYoY: number | null }) {
  return (
    <>
      <TrendBadge change={change} vs="vs last wk" noDataLabel="no prior week" />
      <TrendBadge change={changeYoY} vs="vs last yr" noDataLabel="no data last yr" />
    </>
  )
}

// Chart tooltip title: for weekly points show "W29 · Jul 20" (week number + range).
function weekTooltipLabel(label: unknown, payload?: readonly { payload?: TrendPoint }[]): string {
  const range = payload?.[0]?.payload?.range
  return range ? `${label} · ${range}` : String(label ?? '')
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

/** Shortens "FirstName LastName" / long company names for bar chart ticks. */
const shortName = (n: string) => (n.length > 11 ? `${n.slice(0, 10)}…` : n)

// The forecast RPCs (cashflow_forecast, slow_pay_risk) are admin/accountant only.
const FINANCE_ROLES = ['admin', 'accountant']

function Mini({ label, value, tone }: { label: string; value: string; tone: 'pos' | 'neg' }) {
  return (
    <div className="rounded-lg bg-surface-2 px-3 py-2">
      <p className="text-xs text-muted">{label}</p>
      <p className={`text-sm font-bold ${tone === 'pos' ? 'text-emerald-600' : 'text-red-600'}`}>{value}</p>
    </div>
  )
}

/** The morning strip: who to call, what's overdue, who's on the fire list. */
function TodayGlance() {
  const colQ = useQuery({ queryKey: ['collections-queue'], queryFn: collectionsQueue, refetchInterval: 600_000, retry: false })
  const kfQ = useQuery({ queryKey: ['keep-fire'], queryFn: () => customerKeepFire(365), staleTime: 30 * 60 * 1000, retry: false })
  const rows = colQ.data ?? []
  if (colQ.isLoading || rows.length === 0) return null
  const top = rows[0]
  const overdueTotal = rows.reduce((s, r) => s + Number(r.overdue_total), 0)
  const fireCount = (kfQ.data ?? []).filter((r) => r.recommendation === 'fire').length
  return (
    <Card
      title="📞 Today"
      actions={
        <Link to="/invoices?tab=collections" className="text-xs font-semibold text-brand">
          Collections →
        </Link>
      }
    >
      <p className="text-sm">
        Call <span className="font-semibold">{top.company_name}</span> first —{' '}
        <span className="font-semibold text-red-600 dark:text-red-300">{money(Number(top.overdue_total))}</span> overdue,
        oldest {top.oldest_days} days{top.phone ? ` · ${top.phone}` : ''}.
      </p>
      <p className="mt-1 text-xs text-muted">
        {money(overdueTotal)} overdue across {rows.length} customers
        {fireCount > 0 && <> · {fireCount} on the <Link to="/reports" className="text-brand hover:underline">fire list</Link></>}
        {top.last_promise?.promised_date && ` · latest promise: ${formatDate(top.last_promise.promised_date)}`}
      </p>
    </Card>
  )
}

/** Home-screen glance at the predictive layer: next-4-week cash + who'll pay late. */
function ForecastGlance() {
  const cfQ = useQuery({ queryKey: ['dash-cashflow'], queryFn: () => cashflowForecast(4), refetchInterval: 300_000 })
  const spQ = useQuery({ queryKey: ['dash-slowpay'], queryFn: slowPayRisk, refetchInterval: 300_000 })
  const weeks = cfQ.data ?? []
  const totalIn = weeks.reduce((s, w) => s + Number(w.expected_in), 0)
  const totalOut = weeks.reduce((s, w) => s + Number(w.expected_out), 0)
  const net = totalIn - totalOut
  const risks = (spQ.data ?? []).filter((r) => r.predicted_days_late > 0).slice(0, 3)

  return (
    <Card
      title="🔮 4-Week Outlook"
      actions={
        <Link to="/invoices?tab=forecast" className="text-xs font-semibold text-brand">
          Open forecast →
        </Link>
      }
    >
      {cfQ.isLoading ? (
        <p className="py-6 text-center text-sm text-muted">Projecting…</p>
      ) : weeks.length === 0 ? (
        <p className="py-6 text-center text-sm text-muted">Not enough billing history to forecast yet.</p>
      ) : (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="grid grid-cols-3 gap-3">
            <Mini label="Expected in" value={money(totalIn)} tone="pos" />
            <Mini label="Expected out" value={money(totalOut)} tone="neg" />
            <Mini label="Net (4 wk)" value={money(net)} tone={net >= 0 ? 'pos' : 'neg'} />
          </div>
          <div>
            <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted">Predicted to pay late</p>
            {risks.length === 0 ? (
              <p className="text-sm text-muted">No open invoices are predicted to slip. 👍</p>
            ) : (
              <ul className="space-y-1 text-sm">
                {risks.map((r) => (
                  <li key={r.invoice_id} className="flex items-center justify-between gap-2">
                    <span className="truncate">{r.customer}</span>
                    <span className="shrink-0 text-amber-600">
                      {money(Number(r.outstanding))} · ~{r.predicted_days_late}d late
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      )}
    </Card>
  )
}

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
        <p className="text-sm text-muted">
          You're signed in as <span className="font-medium capitalize">{user?.role}</span>. Use the menu to reach your modules — company-wide
          dashboards are limited to office staff.
        </p>
      </Card>
    )
  }
  if (summaryQ.isError) return <LoadError error={summaryQ.error} onRetry={() => summaryQ.refetch()} />
  if (isLoading || !data) return <p className="py-8 text-center text-muted">Loading dashboard…</p>

  // Weekly view labels the X-axis by standard week number (e.g. "W29"); the full
  // date range stays in each point's `range` for the chart tooltip.
  const rawTrend: TrendPoint[] = (period === 'weekly' ? data.trend_weekly : data.trend_monthly) ?? []
  const trend = rawTrend.map((p) =>
    period === 'weekly' && p.week
      ? { ...p, range: p.label, label: `W${p.week.split('-W')[1]}` }
      : p,
  )
  const statusPills = Object.entries(data.status_counts).filter(([, v]) => v > 0)

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <h1 className="text-xl font-bold text-body">Dashboard</h1>
          <span className="rounded-full border border-line bg-surface-2 px-2.5 py-0.5 text-xs font-medium text-muted" title="Standard week: Monday–Sunday. Week 0 is a partial start-of-year week.">
            📅 {weekTitle(new Date(data.week_start + 'T00:00:00'))}
          </span>
        </div>
        <div className="flex gap-2">
          <Button onClick={() => navigate('/dispatch')}>+ New Load</Button>
          <Button variant="secondary" onClick={() => navigate('/reports')}>
            Weekly Report
          </Button>
        </div>
      </div>

      {/* KPI cards — this week vs last week */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          label="Week Revenue"
          value={money(data.week_revenue)}
          icon="💰"
          color="blue"
          footer={<KpiTrend change={pctChange(data.week_revenue, data.prev_week?.revenue ?? 0)} changeYoY={pctChange(data.week_revenue, data.prev_year_week?.revenue ?? 0)} />}
        />
        <StatCard
          label="Week Miles"
          value={Number(data.week_miles).toLocaleString()}
          icon="🛣️"
          color="amber"
          footer={<KpiTrend change={pctChange(Number(data.week_miles), Number(data.prev_week?.miles ?? 0))} changeYoY={pctChange(Number(data.week_miles), Number(data.prev_year_week?.miles ?? 0))} />}
        />
        <StatCard
          label="Week Loads"
          value={String(data.week_loads)}
          icon="📦"
          color="green"
          footer={<KpiTrend change={pctChange(data.week_loads, data.prev_week?.loads ?? 0)} changeYoY={pctChange(data.week_loads, data.prev_year_week?.loads ?? 0)} />}
        />
        <StatCard
          label="Avg Rate / Mile"
          value={data.week_avg_rate_per_mile != null ? `$${Number(data.week_avg_rate_per_mile).toFixed(2)}` : '—'}
          icon="📈"
          color="red"
          footer={
            <KpiTrend
              change={pctChange(Number(data.week_avg_rate_per_mile ?? 0), Number(data.prev_week?.avg_rate_per_mile ?? 0))}
              changeYoY={pctChange(Number(data.week_avg_rate_per_mile ?? 0), Number(data.prev_year_week?.avg_rate_per_mile ?? 0))}
            />
          }
        />
      </div>

      {/* Fleet strip: availability + live load statuses */}
      <div className="flex flex-wrap items-center gap-x-6 gap-y-2 rounded-xl bg-surface px-5 py-3 shadow-sm">
        <span className="text-sm font-semibold text-body">
          🚛 {data.available_trucks} truck{data.available_trucks === 1 ? '' : 's'} available
        </span>
        <span className="text-sm font-semibold text-body">🪪 {data.active_drivers} active drivers</span>
        <span className="ml-auto flex flex-wrap items-center gap-1.5">
          {statusPills.map(([status, n]) => (
            <span key={status} className={`rounded-full px-2.5 py-0.5 text-xs font-semibold capitalize ${STATUS_PILL_COLORS[status] ?? 'bg-slate-500/15 text-muted'}`}>
              {status.replace('_', ' ')} {n}
            </span>
          ))}
        </span>
      </div>

      {FINANCE_ROLES.includes(user?.role ?? '') && <TodayGlance />}
      {FINANCE_ROLES.includes(user?.role ?? '') && <ForecastGlance />}

      {/* Revenue trend */}
      <Card title="Revenue Trend" actions={<PeriodSelect value={period} onChange={setPeriod} />}>
        <ResponsiveContainer width="100%" height={240}>
          <AreaChart data={trend}>
            <defs>
              <linearGradient id="gradRevenue" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={CHART.revenue} stopOpacity={0.55} />
                <stop offset="100%" stopColor={CHART.revenue} stopOpacity={0.05} />
              </linearGradient>
            </defs>
            <ChartGrid />
            <ChartXAxis dataKey="label" />
            <ChartYAxis tickFormatter={(v) => `$${(v / 1000).toFixed(0)}k`} />
            <ChartTooltip formatter={(v) => money(Number(v))} labelFormatter={weekTooltipLabel} />
            <Area type="monotone" dataKey="revenue" name="Revenue" stroke={CHART.revenue} strokeWidth={2.5} fill="url(#gradRevenue)" />
          </AreaChart>
        </ResponsiveContainer>
      </Card>

      {/* Miles trend — loaded vs empty */}
      <Card
        title="Miles Trend"
        actions={
          <div className="flex items-center gap-4">
            <LegendChip color={CHART.positive} label="Total miles" />
            <LegendChip color={CHART.warn} label="Empty miles" />
            <PeriodSelect value={period} onChange={setPeriod} />
          </div>
        }
      >
        <ResponsiveContainer width="100%" height={220}>
          <AreaChart data={trend}>
            <defs>
              <linearGradient id="gradMiles" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={CHART.positive} stopOpacity={0.5} />
                <stop offset="100%" stopColor={CHART.positive} stopOpacity={0.05} />
              </linearGradient>
              <linearGradient id="gradEmpty" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={CHART.warn} stopOpacity={0.5} />
                <stop offset="100%" stopColor={CHART.warn} stopOpacity={0.05} />
              </linearGradient>
            </defs>
            <ChartGrid />
            <ChartXAxis dataKey="label" />
            <ChartYAxis tickFormatter={(v) => Number(v).toLocaleString()} />
            <ChartTooltip formatter={(v) => Number(v).toLocaleString()} labelFormatter={weekTooltipLabel} />
            <Area type="monotone" dataKey="miles" name="Total miles" stroke={CHART.positive} strokeWidth={2.5} fill="url(#gradMiles)" />
            <Area type="monotone" dataKey="empty_miles" name="Empty miles" stroke={CHART.warn} strokeWidth={2.5} fill="url(#gradEmpty)" />
          </AreaChart>
        </ResponsiveContainer>
      </Card>

      {/* Bottom bar panels */}
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card title="Top Customers (90 days)" actions={<LegendChip color={CHART.positive} label="Revenue" />}>
          {data.top_customers.length === 0 ? (
            <p className="py-16 text-center text-sm text-muted">No completed loads in the last 90 days.</p>
          ) : (
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={data.top_customers.map((c) => ({ ...c, short: shortName(c.name) }))}>
                <ChartGrid />
                <ChartXAxis dataKey="short" tick={{ fontSize: 11, fill: 'var(--muted)' }} interval={0} />
                <ChartYAxis tickFormatter={(v) => `$${(v / 1000).toFixed(0)}k`} />
                <ChartTooltip formatter={(v) => money(Number(v))} labelFormatter={(_, p) => p?.[0]?.payload?.name ?? ''} />
                <Bar dataKey="revenue" name="Revenue" fill={CHART.positive} radius={[6, 6, 0, 0]} maxBarSize={42} />
              </BarChart>
            </ResponsiveContainer>
          )}
        </Card>
        <Card title="Driver Performance (30 days)" actions={<LegendChip color={CHART.warn} label="Miles" />}>
          {data.driver_perf.length === 0 ? (
            <p className="py-16 text-center text-sm text-muted">No completed loads in the last 30 days.</p>
          ) : (
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={data.driver_perf.map((d) => ({ ...d, short: shortName(d.name) }))}>
                <ChartGrid />
                <ChartXAxis dataKey="short" tick={{ fontSize: 11, fill: 'var(--muted)' }} interval={0} />
                <ChartYAxis tickFormatter={(v) => Number(v).toLocaleString()} />
                <ChartTooltip
                  formatter={(v, name) => (name === 'Miles' ? Number(v).toLocaleString() : money(Number(v)))}
                  labelFormatter={(_, p) => p?.[0]?.payload?.name ?? ''}
                />
                <Bar dataKey="miles" name="Miles" fill={CHART.warn} radius={[6, 6, 0, 0]} maxBarSize={42} />
              </BarChart>
            </ResponsiveContainer>
          )}
        </Card>
      </div>

      {data.expiring_licenses.length > 0 && (
        <Card title="⚠️ Licenses Expiring Within 30 Days">
          <ul className="divide-y divide-line text-sm">
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
          <p className="py-6 text-center text-sm text-muted">No loads currently assigned or in transit.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-line text-left">
                  {['Load #', 'Customer', 'Route', 'Driver', 'Pickup', 'Status'].map((h) => (
                    <th key={h} className="px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-muted">
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {data.active_loads.map((l) => (
                  <tr key={l.id} className="cursor-pointer hover:bg-surface-2" onClick={() => navigate(`/loads/${l.id}`)}>
                    <td className="px-3 py-3 font-medium text-brand">
                      <Link to={`/loads/${l.id}`} onClick={(e) => e.stopPropagation()}>
                        {l.load_number}
                      </Link>
                    </td>
                    <td className="px-3 py-3">{l.customer_name}</td>
                    <td className="max-w-60 truncate px-3 py-3">
                      {cityState(l.pickup_address)} → {cityState(l.delivery_address)}
                    </td>
                    <td className="px-3 py-3">{l.driver_name ?? '—'}</td>
                    <td className="px-3 py-3 text-muted">{formatDateTime(l.pickup_time)}</td>
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

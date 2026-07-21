import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Button, Card, LoadError, money, Table } from '../components/ui'
import { driverScorecard, laneSummary, weeklyFlash, weeklyReport } from '../data'
import type { WeeklyRow } from '../types'

function FlashStat({ label, value, accent }: { label: string; value: string; accent?: string }) {
  return (
    <div>
      <div className="text-[10px] font-semibold uppercase tracking-wide text-muted">{label}</div>
      <div className={`text-lg font-bold ${accent ?? 'text-body'}`}>{value}</div>
    </div>
  )
}

/** The playbook's weekly ops/cash/safety flash, one strip above the report. */
function OwnerFlash({ weekOffset }: { weekOffset: number }) {
  const q = useQuery({ queryKey: ['weekly-flash', weekOffset], queryFn: () => weeklyFlash(weekOffset), retry: false })
  const f = q.data
  if (q.isError || !f) return null
  const num = (v: number | null | undefined, digits = 0) =>
    v == null ? '—' : Number(v).toLocaleString(undefined, { maximumFractionDigits: digits })
  const safetyEvents = (f.safety?.accidents_in_window ?? 0) as number
  return (
    <Card title={`⚡ Owner Flash — ${f.week.label}`}>
      <div className="grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-4 lg:grid-cols-8">
        <FlashStat label="Revenue" value={f.ops.revenue != null ? money(f.ops.revenue) : '—'} accent="text-brand" />
        <FlashStat label="Net" value={f.ops.net != null ? money(f.ops.net) : '—'} />
        <FlashStat label="Loads" value={num(f.ops.loads)} />
        <FlashStat label="On-time" value={f.ops.on_time_pct != null ? `${f.ops.on_time_pct}%` : '—'} />
        <FlashStat label="Collected" value={money(f.cash.collected_this_week)} accent="text-emerald-600 dark:text-emerald-400" />
        <FlashStat label="AR open" value={money(f.cash.ar_outstanding)} />
        <FlashStat label="Detention hrs" value={num(f.ops.detention_hours, 1)} />
        <FlashStat
          label="Alerts"
          value={`${f.sentinel.open}${f.sentinel.critical ? ` (${f.sentinel.critical}⚠)` : ''}`}
          accent={f.sentinel.critical ? 'text-rose-600 dark:text-rose-400' : safetyEvents ? 'text-amber-600' : undefined}
        />
      </div>
    </Card>
  )
}

/** Weekly per-driver card: revenue, pay, on-time, detention, violations. */
function DriverCards({ weekOffset }: { weekOffset: number }) {
  const q = useQuery({ queryKey: ['driver-scorecard', weekOffset], queryFn: () => driverScorecard(weekOffset), retry: false })
  const s = q.data
  if (q.isError || !s || s.drivers.length === 0) return null
  return (
    <Card title="🧑‍✈️ Driver Scorecards">
      <Table headers={['Driver', 'Loads', 'Miles', 'Revenue', '$/mi', 'Pay', 'On-time', 'Detention hrs', 'Violations']}>
        {s.drivers.map((d) => (
          <tr key={d.driver}>
            <td className="px-3 py-2 font-medium">{d.driver}</td>
            <td className="px-3 py-2">{d.loads}</td>
            <td className="px-3 py-2">{Number(d.total_miles).toLocaleString()}</td>
            <td className="px-3 py-2">{money(d.revenue)}</td>
            <td className="px-3 py-2">{d.rpm != null ? `$${Number(d.rpm).toFixed(2)}` : '—'}</td>
            <td className="px-3 py-2 font-semibold text-brand">{money(d.est_pay)}</td>
            <td className="px-3 py-2">{d.on_time_pct != null ? `${d.on_time_pct}%` : '—'}</td>
            <td className="px-3 py-2">{Number(d.detention_hours) > 0 ? d.detention_hours : '—'}</td>
            <td className={`px-3 py-2 ${d.violations > 0 ? 'font-semibold text-rose-600 dark:text-rose-400' : ''}`}>
              {d.violations > 0 ? d.violations : '—'}
            </td>
          </tr>
        ))}
      </Table>
      <p className="mt-1 text-[11px] text-muted">
        On-time is measured from ELD arrival vs appointment (+2h grace) where GPS coverage exists; detention from measured dwell on the driver&rsquo;s loads.
      </p>
    </Card>
  )
}

/** Every state→state lane, ranked by revenue, margined at the GL all-in $/mi. */
function LanesCard() {
  const [days, setDays] = useState(180)
  const q = useQuery({ queryKey: ['lane-summary', days], queryFn: () => laneSummary(days), retry: false })
  const s = q.data
  if (q.isError || (s && s.lanes.length === 0)) return null
  return (
    <Card title={`🛣️ Lanes — last ${days} days`}>
      <div className="mb-2 flex items-center justify-between">
        <span className="text-xs text-muted">
          Margin at the books&rsquo; all-in cost of ${Number(s?.all_in_rpm_basis ?? 0).toFixed(2)}/mi (fuel, pay, overhead — everything).
        </span>
        <div className="flex gap-1">
          {[90, 180, 365].map((d) => (
            <Button key={d} variant={d === days ? 'primary' : 'secondary'} onClick={() => setDays(d)}>{d}d</Button>
          ))}
        </div>
      </div>
      {!s ? (
        <p className="py-4 text-center text-sm text-muted">Loading…</p>
      ) : (
        <Table headers={['Lane', 'Loads', 'Revenue', '$/mi', 'Margin', 'Margin %', 'Deadhead %', 'Last run']}>
          {s.lanes.map((l) => (
            <tr key={l.lane} className={l.below_breakeven ? 'bg-rose-50 dark:bg-rose-950/30' : undefined}>
              <td className="px-3 py-2 font-medium">
                {l.lane}
                {l.below_breakeven && (
                  <span className="ml-2 rounded-full bg-rose-100 px-2 py-0.5 text-[10px] font-semibold text-rose-700 dark:bg-rose-900/50 dark:text-rose-300">
                    below break-even
                  </span>
                )}
              </td>
              <td className="px-3 py-2">{l.loads}</td>
              <td className="px-3 py-2">{money(l.revenue)}</td>
              <td className="px-3 py-2">{l.rpm != null ? `$${Number(l.rpm).toFixed(2)}` : '—'}</td>
              <td className={`px-3 py-2 font-semibold ${Number(l.est_margin) < 0 ? 'text-rose-600 dark:text-rose-400' : ''}`}>
                {l.est_margin != null ? money(l.est_margin) : '—'}
              </td>
              <td className="px-3 py-2">{l.margin_pct != null ? `${l.margin_pct}%` : '—'}</td>
              <td className="px-3 py-2">{l.deadhead_pct != null ? `${l.deadhead_pct}%` : '—'}</td>
              <td className="px-3 py-2 text-muted">{new Date(l.last_run + 'T00:00:00').toLocaleDateString()}</td>
            </tr>
          ))}
        </Table>
      )}
    </Card>
  )
}

function shiftWeek(dateStr: string, weeks: number): string {
  const d = new Date(dateStr + 'T00:00:00')
  d.setDate(d.getDate() + weeks * 7)
  return d.toISOString().slice(0, 10)
}

function todayISO(): string {
  return new Date().toISOString().slice(0, 10)
}

function ReportTable({ title, rows, isDriver }: { title: string; rows: WeeklyRow[]; isDriver?: boolean }) {
  return (
    <Card title={title}>
      {rows.length === 0 ? (
        <p className="py-6 text-center text-sm text-muted">No completed loads this week.</p>
      ) : (
        <Table headers={[
          isDriver ? 'Driver' : 'Truck', 'Loads', 'Miles',
          ...(isDriver ? ['Empty Mi.'] : []),
          'Revenue', 'Avg $/Mile',
          ...(isDriver ? ['Driver Pay'] : ['Fuel', 'MPG', 'Net After Fuel']),
        ]}>
          {rows.map((r) => (
            <tr key={r.key_id}>
              <td className="px-3 py-3 font-medium">{r.name}</td>
              <td className="px-3 py-3">{r.loads}</td>
              <td className="px-3 py-3">{Number(r.miles).toLocaleString()}</td>
              {isDriver && <td className="px-3 py-3">{Number(r.empty_miles ?? 0).toLocaleString()}</td>}
              <td className="px-3 py-3">{money(r.revenue)}</td>
              <td className="px-3 py-3">{r.avg_rate_per_mile != null ? `$${Number(r.avg_rate_per_mile).toFixed(2)}` : '—'}</td>
              {isDriver && <td className="px-3 py-3 font-semibold text-brand">{money(r.driver_pay ?? null)}</td>}
              {!isDriver && <td className="px-3 py-3 text-amber-600 dark:text-amber-400">{r.fuel_cost ? money(r.fuel_cost) : '—'}</td>}
              {!isDriver && <td className="px-3 py-3">{r.mpg != null ? Number(r.mpg).toFixed(2) : '—'}</td>}
              {!isDriver && <td className="px-3 py-3 font-semibold">{r.net_after_fuel != null ? money(r.net_after_fuel) : '—'}</td>}
            </tr>
          ))}
        </Table>
      )}
    </Card>
  )
}

export default function Reports() {
  const [weekOf, setWeekOf] = useState(todayISO())

  const reportQ = useQuery({
    queryKey: ['weekly-report', weekOf],
    queryFn: () => weeklyReport(weekOf),
  })
  const { data, isLoading } = reportQ

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-bold text-body">Weekly Accounting Report</h1>
        <div className="flex items-center gap-2">
          <Button variant="secondary" onClick={() => setWeekOf(shiftWeek(weekOf, -1))}>
            ← Prev
          </Button>
          {data && (
            <span className="flex flex-col items-center px-2 text-sm font-medium leading-tight">
              <span className="text-xs font-semibold text-brand" title="Standard week: Monday–Sunday. Week 0 is a partial start-of-year week.">
                Week {data.week_number}
              </span>
              <span>
                {new Date(data.week_start + 'T00:00:00').toLocaleDateString()} – {new Date(data.week_end + 'T00:00:00').toLocaleDateString()}
              </span>
            </span>
          )}
          <Button variant="secondary" onClick={() => setWeekOf(shiftWeek(weekOf, 1))}>
            Next →
          </Button>
          <Button variant="secondary" onClick={() => setWeekOf(todayISO())}>
            This Week
          </Button>
        </div>
      </div>

      {reportQ.isError ? (
        <LoadError error={reportQ.error} onRetry={() => reportQ.refetch()} />
      ) : isLoading || !data ? (
        <p className="py-8 text-center text-muted">Loading…</p>
      ) : (
        <>
          <OwnerFlash weekOffset={Math.round((new Date(weekOf + 'T00:00:00').getTime() - new Date(todayISO() + 'T00:00:00').getTime()) / (7 * 86400000))} />
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
            <Card>
              <div className="text-xs font-semibold uppercase text-muted">Loads Completed</div>
              <div className="mt-1 text-2xl font-bold">{data.totals.loads}</div>
            </Card>
            <Card>
              <div className="text-xs font-semibold uppercase text-muted">Total Miles</div>
              <div className="mt-1 text-2xl font-bold">{Number(data.totals.miles).toLocaleString()}</div>
            </Card>
            <Card>
              <div className="text-xs font-semibold uppercase text-muted">Total Revenue</div>
              <div className="mt-1 text-2xl font-bold text-brand">{money(data.totals.revenue)}</div>
            </Card>
            <Card>
              <div className="text-xs font-semibold uppercase text-muted">Avg Revenue / Mile</div>
              <div className="mt-1 text-2xl font-bold">
                {data.totals.avg_rate_per_mile != null ? `$${Number(data.totals.avg_rate_per_mile).toFixed(2)}` : '—'}
              </div>
            </Card>
          </div>
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-3">
            <Card>
              <div className="text-xs font-semibold uppercase text-muted">Fuel Cost</div>
              <div className="mt-1 text-2xl font-bold text-amber-600 dark:text-amber-400">{money(data.totals.fuel_cost ?? 0)}</div>
              {data.totals.fuel_pct_of_revenue != null && (
                <div className="mt-0.5 text-xs text-muted">{Number(data.totals.fuel_pct_of_revenue).toFixed(1)}% of revenue</div>
              )}
            </Card>
            <Card>
              <div className="text-xs font-semibold uppercase text-muted">Fuel Gallons</div>
              <div className="mt-1 text-2xl font-bold">{Number(data.totals.fuel_gallons ?? 0).toLocaleString()}</div>
            </Card>
            <Card>
              <div className="text-xs font-semibold uppercase text-muted">Net After Fuel</div>
              <div className="mt-1 text-2xl font-bold">{money(data.totals.net_after_fuel ?? data.totals.revenue)}</div>
            </Card>
          </div>
          <ReportTable title="By Truck" rows={data.by_truck} />
          <ReportTable title="By Driver" rows={data.by_driver} isDriver />
          <DriverCards weekOffset={Math.max(0, Math.round((new Date(todayISO() + 'T00:00:00').getTime() - new Date(weekOf + 'T00:00:00').getTime()) / (7 * 86400000)))} />
          <LanesCard />
        </>
      )}
    </div>
  )
}

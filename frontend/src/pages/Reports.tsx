import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button, Card, LoadError, money, Table } from '../components/ui'
import { customerKeepFire, dotAuditPack, driverNpsSummary, driverScorecard, financeMarch, laneSummary, loadActuals, storageUsageReport, stressTest, weeklyFlash, weeklyReport, type ScenarioResult } from '../data'
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

/** The audit binder in numbers: what an auditor asks for vs what's on file. */
function DotAuditCard() {
  const q = useQuery({ queryKey: ['dot-audit-pack'], queryFn: dotAuditPack, retry: false })
  const p = q.data
  if (q.isError || !p) return null
  const stat = (label: string, have: number, want: number) => (
    <div key={label}>
      <div className="text-[10px] font-semibold uppercase tracking-wide text-muted">{label}</div>
      <div className={`text-lg font-bold ${have >= want ? 'text-green-700 dark:text-green-300' : 'text-rose-600 dark:text-rose-400'}`}>
        {have}/{want}
      </div>
    </div>
  )
  const flags: string[] = [
    ...p.cdl_expired.map((c) => `CDL expired: ${c.driver}`),
    ...p.medcard_expired.map((c) => `Med card expired: ${c.driver}`),
    ...p.plates_expired.map((c) => `Plate expired: unit ${c.unit}`),
  ]
  return (
    <Card title="🛃 DOT Audit Readiness">
      <div className="grid grid-cols-3 gap-3 sm:grid-cols-5">
        {stat('CDL on file', p.cdl_on_file, p.drivers_active)}
        {stat('Med cards', p.medcard_on_file, p.drivers_active)}
        {stat('DQF complete', p.dqf_complete, p.drivers_active)}
        {stat('MVR reviews 12m', p.mvr_reviewed_12m, p.drivers_active)}
        {stat('Clearinghouse 12m', p.clearinghouse_12m, p.drivers_active)}
        {stat('Testing pool', p.drug_pool_enrolled, p.drivers_active)}
        {stat('Annual inspections', p.annual_inspection_current, p.trucks_active)}
        {stat('ELD reporting 7d', p.eld_reporting_7d, p.trucks_active)}
        {stat('DVIR drivers 30d', p.dvir_drivers_30d, p.drivers_active)}
      </div>
      {flags.length > 0 && (
        <ul className="mt-3 list-inside list-disc text-sm text-rose-600 dark:text-rose-400">
          {flags.map((f) => <li key={f}>{f}</li>)}
        </ul>
      )}
      <p className="mt-2 text-[11px] text-muted">
        Not tracked: {p.not_tracked.join('; ')}. Fix records on the Drivers / Equipment pages; log MVR &amp; Clearinghouse in the Compliance log.
      </p>
    </Card>
  )
}

/** R9 #112: where the document storage actually goes (pairs with the
 * growth-anomaly sentinel — this is the "look for yourself" view). */
function StorageCard() {
  const q = useQuery({ queryKey: ['storage-usage'], queryFn: storageUsageReport, retry: false, staleTime: 10 * 60 * 1000 })
  const s = q.data
  if (q.isError || !s) return null
  const mb = (b: number) => b > 1024 * 1024 * 1024 ? `${(b / 1073741824).toFixed(1)} GB` : `${Math.max(1, Math.round(b / 1048576))} MB`
  const months = s.monthly.slice(-6)
  return (
    <Card title="🗄️ Document storage">
      <p className="text-sm text-body">
        <span className="font-semibold">{mb(s.total_bytes)}</span> across {s.docs.toLocaleString()} documents —{' '}
        {Object.entries(s.by_type).sort((a, b) => b[1].bytes - a[1].bytes).slice(0, 4)
          .map(([t, v]) => `${t} ${mb(v.bytes)}`).join(' · ')}
      </p>
      {months.length > 1 && (
        <p className="mt-1 text-xs text-muted">
          Monthly intake: {months.map((m) => `${m.month.slice(5)}: ${mb(m.bytes)}`).join(' → ')}
        </p>
      )}
      {s.largest.length > 0 && (
        <p className="mt-1 text-xs text-muted">
          Largest: {s.largest.slice(0, 3).map((l) => `${l.filename} (${mb(l.bytes)})`).join(' · ')}
        </p>
      )}
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
      <Table headers={['Driver', 'Loads', 'Miles', 'Revenue', '$/mi', 'Pay', 'On-time', 'Detention hrs', 'Violations', 'DVIR', 'Harsh']}>
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
            <td className={`px-3 py-2 ${d.dvir_pct != null && d.dvir_pct < 100 ? 'font-semibold text-amber-600 dark:text-amber-400' : ''}`}>
              {d.dvir_pct != null ? `${d.dvir_pct}%` : '—'}
            </td>
            <td className={`px-3 py-2 ${d.harsh_brakes > 0 ? 'font-semibold text-rose-600 dark:text-rose-400' : ''}`}>
              {d.harsh_brakes > 0 ? d.harsh_brakes : '—'}
            </td>
          </tr>
        ))}
      </Table>
      <p className="mt-1 text-[11px] text-muted">
        On-time is measured from ELD arrival vs appointment (+2h grace) where GPS coverage exists; detention from measured dwell on the driver&rsquo;s loads.
        DVIR is pre-trip inspection days over ELD driving days (&mdash; when the ELD tracked no driving). Harsh is a GPS-decel proxy (25+ mph lost in ~10s), not OEM accelerometer events.
      </p>
    </Card>
  )
}

/** Every state→state lane, ranked by revenue, margined at the GL all-in $/mi. */
const REC_STYLE: Record<string, string> = {
  grow: 'bg-emerald-500/15 text-emerald-700 dark:text-emerald-300',
  keep: 'bg-surface-2 text-muted',
  'fix-price': 'bg-amber-500/15 text-amber-700 dark:text-amber-300',
  fire: 'bg-red-500/15 text-red-700 dark:text-red-300',
}

function KeepFireCard() {
  const q = useQuery({ queryKey: ['keep-fire'], queryFn: () => customerKeepFire(365), retry: false })
  const rows = q.data ?? []
  if (q.isError || rows.length === 0) return null
  const interesting = rows.filter((r) => r.recommendation !== 'keep' || Number(r.revenue) > 10000)
  return (
    <Card title="⚖️ Keep or fire — the quarterly customer call (12 months)">
      <Table headers={['Customer', 'Revenue', 'Margin', 'Pays in', 'Call', 'Why']}>
        {interesting.map((r) => (
          <tr key={r.customer_id} className="hover:bg-surface-2">
            <td className="px-3 py-2.5 font-medium">{r.company_name}</td>
            <td className="px-3 py-2.5">{money(Number(r.revenue))}</td>
            <td className={`px-3 py-2.5 ${Number(r.margin) < 0 ? 'text-red-600 dark:text-red-300' : ''}`}>
              {money(Number(r.margin))}{r.margin_pct != null && ` (${r.margin_pct}%)`}
            </td>
            <td className="px-3 py-2.5 text-muted">{r.avg_days_to_pay != null ? `${Math.round(Number(r.avg_days_to_pay))}d` : '—'}</td>
            <td className="px-3 py-2.5">
              <span className={`rounded-full px-2 py-0.5 text-xs font-semibold ${REC_STYLE[r.recommendation]}`}>
                {r.recommendation}
              </span>
            </td>
            <td className="px-3 py-2.5 text-xs text-muted">{r.reason || '—'}</td>
          </tr>
        ))}
      </Table>
    </Card>
  )
}

/** Pricing discipline — the money quietly left on the table at booking time. */
function PricingDisciplineCard() {
  const q = useQuery({ queryKey: ['finance-march'], queryFn: financeMarch, retry: false })
  const d = q.data
  if (q.isError || !d) return null
  const pct = (v: number | null, digits = 1) => (v == null ? '—' : `${Number(v).toFixed(digits)}%`)
  const belowFull = d.pct_revenue_below_full_cost
  return (
    <Card title="🎯 Pricing discipline & growth">
      <p className="mb-3 text-xs text-muted">
        Below-cost shares are trailing-90d revenue booked under the fleet's variable
        (${Number(d.variable_rpm_used).toFixed(2)}/mi) and fully-allocated
        ({d.breakeven_rpm_used != null ? `$${Number(d.breakeven_rpm_used).toFixed(2)}/mi` : '—'}) cost.
        Every point of "below full cost" is revenue that pays the bills but not the business.
      </p>
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
        <FlashStat label="YTD revenue vs last year" value={pct(d.ytd_revenue_growth_yoy_pct)} accent={d.ytd_revenue_growth_yoy_pct != null && d.ytd_revenue_growth_yoy_pct >= 0 ? 'text-green-600 dark:text-green-300' : 'text-red-600 dark:text-red-300'} />
        <FlashStat label="QTD EBITDA margin" value={pct(d.qtd_ebitda_margin_pct)} />
        <FlashStat label="Rev below variable cost" value={pct(d.pct_revenue_below_variable_cost)} accent={Number(d.pct_revenue_below_variable_cost) > 2 ? 'text-red-600 dark:text-red-300' : undefined} />
        <FlashStat label="Rev below full cost" value={pct(belowFull)} accent={Number(belowFull) >= 10 ? 'text-red-600 dark:text-red-300' : Number(belowFull) >= 5 ? 'text-amber-600 dark:text-amber-300' : undefined} />
        <FlashStat label="Top-10 customer share" value={pct(d.top10_profit_concentration_pct, 0)} accent={Number(d.top10_profit_concentration_pct) >= 80 ? 'text-amber-600 dark:text-amber-300' : undefined} />
      </div>
    </Card>
  )
}

function ActualsCard() {
  const q = useQuery({ queryKey: ['load-actuals'], queryFn: () => loadActuals(30), retry: false })
  const rows = q.data ?? []
  if (q.isError || rows.length === 0) return null
  const worst = [...rows].sort((a, b) => Number(a.variance) - Number(b.variance)).slice(0, 8)
  return (
    <Card title="🎯 Booked vs actual — where estimates lied (30 days)">
      <p className="mb-2 text-xs text-muted">
        Actual = real driver pay + transponder tolls + banked ELD miles (deadhead included) × GL fuel $/mi.
        Negative variance means the load made less than the booking math promised.
      </p>
      <Table headers={['Load', 'Customer', 'Rate', 'Est. margin', 'Actual', 'Variance']}>
        {worst.map((r) => (
          <tr key={r.load_id} className="hover:bg-surface-2">
            <td className="px-3 py-2.5 font-medium text-brand">{r.load_number}</td>
            <td className="px-3 py-2.5">{r.customer}</td>
            <td className="px-3 py-2.5">{money(Number(r.rate))}</td>
            <td className="px-3 py-2.5 text-muted">{money(Number(r.est_margin))}</td>
            <td className="px-3 py-2.5 font-semibold">{money(Number(r.actual_margin))}</td>
            <td className={`px-3 py-2.5 font-semibold ${Number(r.variance) < 0 ? 'text-red-600 dark:text-red-300' : 'text-emerald-700 dark:text-emerald-300'}`}>
              {Number(r.variance) > 0 ? '+' : ''}{money(Number(r.variance))}
            </td>
          </tr>
        ))}
      </Table>
    </Card>
  )
}

function NpsCard() {
  const q = useQuery({ queryKey: ['driver-nps'], queryFn: driverNpsSummary, retry: false })
  const rows = q.data ?? []
  if (q.isError) return null
  if (rows.length === 0) {
    return (
      <Card title="🚚 Driver NPS">
        <p className="py-4 text-center text-sm text-muted">
          No responses yet — the quarterly survey is live in the driver app. Answers are anonymous to dispatch.
        </p>
      </Card>
    )
  }
  return (
    <Card title="🚚 Driver NPS — anonymous quarterly survey">
      {rows.map((r) => (
        <div key={r.quarter} className="mb-3">
          <div className="flex items-baseline gap-3">
            <span className="font-medium">{r.quarter}</span>
            <span className={`text-2xl font-bold ${Number(r.nps) >= 30 ? 'text-emerald-700 dark:text-emerald-300' : Number(r.nps) >= 0 ? 'text-amber-700 dark:text-amber-300' : 'text-red-600 dark:text-red-300'}`}>
              {Number(r.nps) > 0 ? '+' : ''}{r.nps}
            </span>
            <span className="text-sm text-muted">
              {r.responses} response{r.responses === 1 ? '' : 's'} · {r.promoters} promoters / {r.passives} passive / {r.detractors} detractors
            </span>
          </div>
          {r.comments.length > 0 && (
            <ul className="mt-1 space-y-0.5 text-sm text-muted">
              {r.comments.map((c, i) => <li key={i}>“{c}”</li>)}
            </ul>
          )}
        </div>
      ))}
    </Card>
  )
}

function StressCard() {
  const q = useQuery({ queryKey: ['stress-test'], queryFn: stressTest, retry: false })
  const p = q.data
  if (q.isError || !p) return null
  const rows: { label: string; s: ScenarioResult }[] = [
    { label: 'Revenue −25%', s: p.revenue_down_25 },
    { label: 'Diesel +40%', s: p.fuel_up_40 },
    { label: 'Insurance +30%', s: p.insurance_up_30 },
    { label: 'Perfect storm (all three)', s: p.perfect_storm },
  ]
  const b = p.baseline.baseline
  return (
    <Card title="🌪️ Stress test — could we survive it?">
      <p className="mb-2 text-xs text-muted">
        Baseline from the books (3-month avg): {money(b.monthly_revenue)}/mo revenue, {money(b.monthly_net)}/mo net,{' '}
        {money(b.cash)} cash. Fuel scales with volume and price; other costs held fixed.
      </p>
      <Table headers={['Scenario', 'Monthly net', 'Runway', 'Verdict']}>
        {rows.map(({ label, s }) => (
          <tr key={label} className="hover:bg-surface-2">
            <td className="px-3 py-2.5 font-medium">{label}</td>
            <td className={`px-3 py-2.5 ${s.shocked.monthly_net < 0 ? 'text-red-600 dark:text-red-300' : ''}`}>
              {money(s.shocked.monthly_net)}
            </td>
            <td className="px-3 py-2.5">{s.runway_months == null ? '∞ (still profitable)' : `${s.runway_months} months`}</td>
            <td className="px-3 py-2.5">
              {s.survives
                ? <span className="text-emerald-700 dark:text-emerald-300">✓ survives</span>
                : <span className="font-semibold text-red-600 dark:text-red-300">✗ under 6 months</span>}
            </td>
          </tr>
        ))}
      </Table>
    </Card>
  )
}

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
          <button
            type="button"
            onClick={() => void import('../invoicePdf').then((m) => m.downloadMonthlyPackage())}
            className="rounded-lg border border-edge px-3 py-1.5 text-sm font-medium text-muted hover:text-body"
            title="One PDF: P&L, cash & AR, ops & safety MTD, playbook movers"
          >📦 Owner package</button>
          <Link to="/reports/board" className="rounded-lg border border-edge px-3 py-1.5 text-sm font-medium text-muted hover:text-body">
            🏦 Lender pack
          </Link>
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
          <DotAuditCard />
          <StorageCard />
          <LanesCard />
          <StressCard />
          <PricingDisciplineCard />
          <ActualsCard />
          <KeepFireCard />
          <NpsCard />
        </>
      )}
    </div>
  )
}

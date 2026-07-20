import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Button, Card, LoadError, money, Table } from '../components/ui'
import { weeklyReport } from '../data'
import type { WeeklyRow } from '../types'

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
        </>
      )}
    </div>
  )
}

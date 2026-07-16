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
        <p className="py-6 text-center text-sm text-slate-500">No completed loads this week.</p>
      ) : (
        <Table headers={[isDriver ? 'Driver' : 'Truck', 'Loads', 'Miles', 'Revenue', 'Avg $/Mile', ...(isDriver ? ['Driver Pay'] : [])]}>
          {rows.map((r) => (
            <tr key={r.key_id}>
              <td className="px-3 py-3 font-medium">{r.name}</td>
              <td className="px-3 py-3">{r.loads}</td>
              <td className="px-3 py-3">{Number(r.miles).toLocaleString()}</td>
              <td className="px-3 py-3">{money(r.revenue)}</td>
              <td className="px-3 py-3">{r.avg_rate_per_mile != null ? `$${Number(r.avg_rate_per_mile).toFixed(2)}` : '—'}</td>
              {isDriver && <td className="px-3 py-3 font-semibold text-navy-700">{money(r.driver_pay ?? null)}</td>}
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
        <h1 className="text-xl font-bold text-navy-800">Weekly Accounting Report</h1>
        <div className="flex items-center gap-2">
          <Button variant="secondary" onClick={() => setWeekOf(shiftWeek(weekOf, -1))}>
            ← Prev
          </Button>
          {data && (
            <span className="px-2 text-sm font-medium">
              {new Date(data.week_start + 'T00:00:00').toLocaleDateString()} – {new Date(data.week_end + 'T00:00:00').toLocaleDateString()}
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
        <p className="py-8 text-center text-slate-500">Loading…</p>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
            <Card>
              <div className="text-xs font-semibold uppercase text-slate-500">Loads Completed</div>
              <div className="mt-1 text-2xl font-bold">{data.totals.loads}</div>
            </Card>
            <Card>
              <div className="text-xs font-semibold uppercase text-slate-500">Total Miles</div>
              <div className="mt-1 text-2xl font-bold">{Number(data.totals.miles).toLocaleString()}</div>
            </Card>
            <Card>
              <div className="text-xs font-semibold uppercase text-slate-500">Total Revenue</div>
              <div className="mt-1 text-2xl font-bold text-navy-700">{money(data.totals.revenue)}</div>
            </Card>
            <Card>
              <div className="text-xs font-semibold uppercase text-slate-500">Avg Revenue / Mile</div>
              <div className="mt-1 text-2xl font-bold">
                {data.totals.avg_rate_per_mile != null ? `$${Number(data.totals.avg_rate_per_mile).toFixed(2)}` : '—'}
              </div>
            </Card>
          </div>
          <ReportTable title="By Truck" rows={data.by_truck} />
          <ReportTable title="By Driver" rows={data.by_driver} isDriver />
        </>
      )}
    </div>
  )
}

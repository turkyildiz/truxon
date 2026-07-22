import { useQuery } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { Card, compareValues, Field, formatDateTime, Input, LoadError, money, StatCard, type SortState, Table, toggleSort } from '../components/ui'
import { listTollTransactions, tollByAgency, tollByTruck } from '../data'

/** Local-time YYYY-MM-DD (date inputs and range math stay in the user's zone). */
function isoDate(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function monthStart(): string {
  const d = new Date()
  return isoDate(new Date(d.getFullYear(), d.getMonth(), 1))
}

/** Category chip — violations (costly overages) read red, everything else slate. */
function CategoryBadge({ category }: { category: string }) {
  const isViolation = category === 'Violation'
  const cls = isViolation
    ? 'bg-red-500/15 text-red-600 dark:text-red-300'
    : 'bg-slate-500/15 text-slate-600 dark:text-slate-300'
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold ${cls}`}>
      <span className="h-1.5 w-1.5 rounded-full bg-current" />
      {category || '—'}
    </span>
  )
}

export default function Tolls() {
  const [start, setStart] = useState(monthStart())
  const [end, setEnd] = useState(isoDate(new Date()))

  const byTruckQ = useQuery({ queryKey: ['tolls', 'by-truck', start, end], queryFn: () => tollByTruck(start, end) })
  const byAgencyQ = useQuery({ queryKey: ['tolls', 'by-agency', start, end], queryFn: () => tollByAgency(start, end) })
  const txnsQ = useQuery({ queryKey: ['tolls', 'txns', start, end], queryFn: () => listTollTransactions({ start, end }) })

  const byTruck = byTruckQ.data ?? []
  const byAgency = byAgencyQ.data ?? []
  const txns = txnsQ.data ?? []

  // Click-to-sort on the recent-tolls list (default: newest first). nulls-last
  // comparator shape copied from the Invoices receivables list.
  const [txnSort, setTxnSort] = useState<SortState>({ key: 'date', dir: 'desc' })
  const sortedTxns = useMemo(() => {
    const val = (t: (typeof txns)[number]): unknown => {
      switch (txnSort.key) {
        case 'date': {
          const d = t.post_date_time ?? t.exit_date_time
          return d ? new Date(d).getTime() : null
        }
        case 'agency': return t.toll_agency_name
        case 'plaza': return t.exit_plaza_name || t.entry_plaza_name
        case 'unit': return t.vehicle_number
        case 'read': return t.read_type
        case 'category': return t.toll_category
        case 'amount': return Number(t.toll_charge)
        default: return null
      }
    }
    const dir = txnSort.dir === 'asc' ? 1 : -1
    // blanks/nulls stay last in BOTH directions (reversing would surface them)
    return [...txns].sort((a, b) => {
      const av = val(a), bv = val(b)
      const aNil = av == null || av === ''
      const bNil = bv == null || bv === ''
      if (aNil && bNil) return 0
      if (aNil) return 1
      if (bNil) return -1
      return dir * compareValues(av, bv)
    })
  }, [txns, txnSort])

  // Headline totals come from the by-truck rollup — server-aggregated over the
  // whole range, so they're not capped by the recent-transactions limit.
  const totalSpend = byTruck.reduce((s, r) => s + Number(r.spend), 0)
  const totalTolls = byTruck.reduce((s, r) => s + Number(r.tolls), 0)
  const totalViolations = byTruck.reduce((s, r) => s + Number(r.violations), 0)
  // Violation $ isn't in the rollup — sum it from the (capped) recent rows.
  const violationSpend = txns.reduce((s, t) => (t.toll_category === 'Violation' ? s + Number(t.toll_charge) : s), 0)

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <h1 className="text-xl font-bold text-body">Tolls</h1>
        <div className="flex flex-wrap items-end gap-3">
          <Field label="From" className="w-40">
            <Input type="date" value={start} max={end} onChange={(e) => setStart(e.target.value)} />
          </Field>
          <Field label="To" className="w-40">
            <Input type="date" value={end} min={start} onChange={(e) => setEnd(e.target.value)} />
          </Field>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label="Total Toll Spend" value={money(totalSpend)} icon="🛣️" color="green" />
        <StatCard label="Tolls" value={totalTolls.toLocaleString()} icon="🧾" color="blue" />
        <StatCard label="Violations" value={totalViolations.toLocaleString()} icon="⚠️" color="red" />
        <StatCard label="Violation $" value={money(violationSpend)} icon="💸" color="amber" />
      </div>

      <Card title="Tolls by Truck">
        {byTruckQ.isError ? (
          <LoadError error={byTruckQ.error} onRetry={() => byTruckQ.refetch()} />
        ) : byTruckQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : byTruck.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No toll spend in this range.</p>
        ) : (
          <Table headers={['Unit', 'Tolls', 'Violations', 'Spend']}>
            {byTruck.map((r) => (
              <tr key={r.truck_id}>
                <td className="px-3 py-3 font-medium">{r.unit_number}</td>
                <td className="px-3 py-3">{Number(r.tolls).toLocaleString()}</td>
                <td className={`px-3 py-3 ${Number(r.violations) > 0 ? 'font-semibold text-red-600 dark:text-red-400' : ''}`}>
                  {Number(r.violations).toLocaleString()}
                </td>
                <td className="px-3 py-3 font-semibold">{money(r.spend)}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Card title="Tolls by Agency / Jurisdiction">
        {byAgencyQ.isError ? (
          <LoadError error={byAgencyQ.error} onRetry={() => byAgencyQ.refetch()} />
        ) : byAgencyQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : byAgency.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No agency data in this range.</p>
        ) : (
          <Table headers={['State', 'Agency', 'Tolls', 'Spend']}>
            {byAgency.map((r, i) => (
              <tr key={`${r.jurisdiction}-${r.agency}-${i}`}>
                <td className="px-3 py-3 font-medium">{r.jurisdiction || '—'}</td>
                <td className="px-3 py-3">{r.agency || '—'}</td>
                <td className="px-3 py-3">{Number(r.tolls).toLocaleString()}</td>
                <td className="px-3 py-3 font-semibold">{money(r.spend)}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Card title="Recent Tolls">
        {txnsQ.isError ? (
          <LoadError error={txnsQ.error} onRetry={() => txnsQ.refetch()} />
        ) : txnsQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : txns.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No tolls in this range.</p>
        ) : (
          <Table
            headers={[
              { label: 'Date', key: 'date' },
              { label: 'Agency', key: 'agency' },
              { label: 'Plaza', key: 'plaza' },
              { label: 'Unit', key: 'unit' },
              { label: 'Read', key: 'read' },
              { label: 'Category', key: 'category' },
              { label: 'Amount', key: 'amount' },
            ]}
            sort={txnSort}
            onSort={(k) => setTxnSort((p) => toggleSort(p, k))}
          >
            {sortedTxns.map((t) => (
              <tr key={t.id} className="hover:bg-surface-2">
                <td className="px-3 py-3 whitespace-nowrap">{formatDateTime(t.post_date_time ?? t.exit_date_time)}</td>
                <td className="px-3 py-3">
                  <div className="font-medium">{t.toll_agency_name || '—'}</div>
                  {t.toll_agency_state && <div className="text-xs text-muted">{t.toll_agency_state}</div>}
                </td>
                <td className="px-3 py-3">
                  {t.entry_plaza_name && t.exit_plaza_name && t.entry_plaza_name !== t.exit_plaza_name
                    ? `${t.entry_plaza_name} → ${t.exit_plaza_name}`
                    : t.exit_plaza_name || t.entry_plaza_name || '—'}
                </td>
                <td className="px-3 py-3">{t.vehicle_number || '—'}</td>
                <td className="px-3 py-3 whitespace-nowrap text-muted">{t.read_type || '—'}</td>
                <td className="px-3 py-3 whitespace-nowrap">
                  <CategoryBadge category={t.toll_category} />
                  {t.dispute_status === 'In Dispute' && (
                    <div className="mt-1 text-xs font-semibold text-amber-600 dark:text-amber-400">In Dispute</div>
                  )}
                </td>
                <td className="px-3 py-3 font-semibold">{money(t.toll_charge)}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
    </div>
  )
}

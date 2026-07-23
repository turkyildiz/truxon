import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useRef, useState } from 'react'
import { Badge, Button, Card, compareValues, Field, formatDateTime, Input, LoadError, money, StatCard, type SortState, Table, toggleSort } from '../components/ui'
import { useAuth } from '../auth'
import { fuelByTruck, fuelIftaSummary, fuelRecon, iftaQuarter, importFuelCsv, listFuelTransactions, truckMpg } from '../data'
import { errorMessage } from '../supabase'
import type { FuelImportResult } from '../types'

/** Local-time YYYY-MM-DD (date inputs and range math stay in the user's zone). */
function isoDate(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function monthStart(): string {
  const d = new Date()
  return isoDate(new Date(d.getFullYear(), d.getMonth(), 1))
}

function quarterLabel(offset = 0): string {
  const d = new Date()
  let q = Math.floor(d.getMonth() / 3) + 1 - offset
  let y = d.getFullYear()
  while (q < 1) { q += 4; y -= 1 }
  return `${y}-Q${q}`
}

/** Real MPG: ELD actual miles ÷ diesel gallons — per truck, fleet, weekly trend. */
function MpgCard() {
  const [days, setDays] = useState(30)
  const q = useQuery({ queryKey: ['fuel', 'mpg', days], queryFn: () => truckMpg(days), retry: false })
  if (q.isError) return null
  const d = q.data
  return (
    <Card title="⚙️ Real MPG (ELD miles ÷ diesel gallons)">
      <div className="mb-2 flex items-center justify-between">
        <span className="text-xs text-muted">
          Miles are actual GPS-banked driving (loaded + deadhead). Fuel only counts toward MPG on days the truck's ELD reported — a dead ELD can't fake a ratio. Per-truck MPG hidden under 30 tracked gal.
        </span>
        <div className="flex gap-1">
          {[14, 30, 90].map((n) => (
            <button
              key={n}
              onClick={() => setDays(n)}
              className={`rounded-lg px-2 py-1 text-xs font-medium ${days === n ? 'bg-surface text-body shadow' : 'text-muted hover:text-body'}`}
            >
              {n}d
            </button>
          ))}
        </div>
      </div>
      {q.isLoading ? (
        <p className="py-8 text-center text-muted">Loading…</p>
      ) : !d || d.trucks.length === 0 ? (
        <p className="py-6 text-center text-sm text-muted">No ELD miles + fuel overlap in this window yet.</p>
      ) : (
        <>
          <div className="mb-3 grid grid-cols-2 gap-4 lg:grid-cols-4">
            <StatCard label="Fleet MPG" value={d.fleet.mpg != null ? d.fleet.mpg.toFixed(2) : '—'} icon="⚙️" color="green" />
            <StatCard label="ELD Miles" value={Math.round(d.fleet.eld_miles).toLocaleString()} icon="🛣️" color="blue" />
            <StatCard label="Diesel Gallons" value={Math.round(d.fleet.gallons).toLocaleString()} icon="🛢️" color="amber" />
            <StatCard label="Fuel $/Mile" value={d.fleet.fuel_cost_per_mile != null ? `$${Number(d.fleet.fuel_cost_per_mile).toFixed(3)}` : '—'} icon="💸" color="purple" />
          </div>
          <Table headers={['Unit', 'ELD miles', 'Days tracked', 'Gallons', 'Tracked gal', 'MPG', 'Fuel $/mi']}>
            {d.trucks.map((t) => (
              <tr key={t.truck_id} className="hover:bg-surface-2">
                <td className="px-3 py-2.5 font-medium">{t.unit_number}</td>
                <td className="px-3 py-2.5">{Math.round(Number(t.eld_miles)).toLocaleString()}</td>
                <td className="px-3 py-2.5 text-muted">{t.days_tracked ?? '—'}</td>
                <td className="px-3 py-2.5">{Number(t.gallons).toLocaleString(undefined, { maximumFractionDigits: 1 })}</td>
                <td className="px-3 py-2.5">{Number(t.gallons_tracked).toLocaleString(undefined, { maximumFractionDigits: 1 })}</td>
                <td className="px-3 py-2.5 font-semibold">{t.mpg != null ? Number(t.mpg).toFixed(2) : '—'}</td>
                <td className="px-3 py-2.5">{t.fuel_cost_per_mile != null ? `$${Number(t.fuel_cost_per_mile).toFixed(3)}` : '—'}</td>
              </tr>
            ))}
          </Table>
          {d.weekly.length > 1 && (
            <p className="mt-2 text-xs text-muted">
              Weekly fleet MPG:{' '}
              {d.weekly.map((w) => `${w.week_start.slice(5)} → ${w.mpg != null ? Number(w.mpg).toFixed(1) : '—'}`).join(' · ')}
            </p>
          )}
        </>
      )}
    </Card>
  )
}

/** The sentinel's diversion check, visible: gallons vs. the miles that justify them. */
function ReconCard() {
  const q = useQuery({ queryKey: ['fuel', 'recon'], queryFn: () => fuelRecon(45), retry: false })
  if (q.isError) return null
  const rows = (q.data ?? []).filter((r) => Number(r.gallons) + Number(r.gallons_untracked) > 0)
  const pill = (text: string, tone: 'red' | 'amber' | 'green' | 'blue' | 'slate') => {
    const cls = {
      red: 'bg-red-500/15 text-red-600 dark:text-red-300',
      amber: 'bg-amber-500/15 text-amber-700 dark:text-amber-300',
      green: 'bg-green-500/15 text-green-700 dark:text-green-300',
      blue: 'bg-blue-500/15 text-blue-600 dark:text-blue-300',
      slate: 'bg-slate-500/15 text-slate-600 dark:text-slate-300',
    }[tone]
    return <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-semibold ${cls}`}>{text}</span>
  }
  const varianceBadge = (v: number | null) => {
    if (v == null) return <span className="text-muted">—</span>
    return pill(`${v > 0 ? '+' : ''}${Math.round(v)}%`, v >= 25 ? 'red' : v >= 10 ? 'amber' : 'green')
  }
  return (
    <Card title="🕵️ Fuel vs. miles — 45d reconciliation">
      <p className="mb-2 text-xs text-muted">
        Same math as the fuel-diversion sentinel: gallons only count on days the truck banked GPS miles ("basis: eld"; booked dispatch miles for ELD-dark trucks).
        Variance is purchased vs. expected gallons at 6.5 MPG — sustained +25% on clean coverage is worth a conversation.
        "Off-day gal" is fuel bought while the ELD reported nothing; a dark ELD plus a full tank is its own red flag.
      </p>
      {q.isLoading ? (
        <p className="py-8 text-center text-muted">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="py-6 text-center text-sm text-muted">No fuel purchases in the window.</p>
      ) : (
        <Table headers={['Unit', 'Miles', 'Basis', 'Gallons', 'Off-day gal', 'MPG', 'Variance']}>
          {rows.map((r) => (
            <tr key={r.truck_id} className="hover:bg-surface-2">
              <td className="px-3 py-2.5 font-medium">{r.unit_number}</td>
              <td className="px-3 py-2.5">{Math.round(Number(r.total_miles)).toLocaleString()}</td>
              <td className="px-3 py-2.5">
                {pill(r.miles_basis, r.miles_basis === 'eld' ? 'blue' : 'slate')}
              </td>
              <td className="px-3 py-2.5">{Number(r.gallons).toLocaleString(undefined, { maximumFractionDigits: 1 })}</td>
              <td className="px-3 py-2.5">
                {Number(r.gallons_untracked) > 0
                  ? <span className="font-medium text-amber-600 dark:text-amber-400">{Number(r.gallons_untracked).toLocaleString(undefined, { maximumFractionDigits: 1 })}</span>
                  : <span className="text-muted">—</span>}
              </td>
              <td className="px-3 py-2.5">{r.implied_mpg != null ? Number(r.implied_mpg).toFixed(2) : '—'}</td>
              <td className="px-3 py-2.5">{varianceBadge(r.gallon_variance_pct != null ? Number(r.gallon_variance_pct) : null)}</td>
            </tr>
          ))}
        </Table>
      )}
    </Card>
  )
}

/** The filing view: GPS-attributed MILES per jurisdiction + fuel bought there. */
function IftaQuarterCard() {
  const [quarter, setQuarter] = useState(quarterLabel(0))
  const q = useQuery({ queryKey: ['ifta-quarter', quarter], queryFn: () => iftaQuarter(quarter), retry: false })
  if (q.isError) return null
  const rows = q.data ?? []
  const totalMiles = rows.reduce((s, r) => s + Number(r.miles), 0)
  return (
    <Card title="🗺️ IFTA quarter — filing view (GPS miles by jurisdiction)">
      <div className="mb-2 flex items-center justify-between">
        <span className="text-xs text-muted">
          Miles from banked ELD breadcrumbs attributed by state polygon; gallons/spend are purchases in that state.
          {totalMiles > 0 && ` Total ${Math.round(totalMiles).toLocaleString()} mi.`}
        </span>
        <div className="flex gap-1">
          {[quarterLabel(1), quarterLabel(0)].map((lbl) => (
            <button
              key={lbl}
              onClick={() => setQuarter(lbl)}
              className={`rounded-lg px-2 py-1 text-xs font-medium ${quarter === lbl ? 'bg-surface text-body shadow' : 'text-muted hover:text-body'}`}
            >
              {lbl}
            </button>
          ))}
        </div>
      </div>
      {rows.length === 0 ? (
        <p className="py-6 text-center text-sm text-muted">No attributed miles in {quarter} yet — the GPS bank started 2026-07-19.</p>
      ) : (
        <Table headers={['Jurisdiction', 'Miles', 'Share', 'Gallons bought', 'Fuel spend']}>
          {rows.map((r) => (
            <tr key={r.jurisdiction} className="hover:bg-surface-2">
              <td className="px-3 py-2.5 font-medium">{r.jurisdiction || 'unattributed'}</td>
              <td className="px-3 py-2.5">{Math.round(Number(r.miles)).toLocaleString()}</td>
              <td className="px-3 py-2.5 text-muted">{Number(r.share_pct).toFixed(1)}%</td>
              <td className="px-3 py-2.5">{Number(r.gallons) > 0 ? Number(r.gallons).toLocaleString(undefined, { maximumFractionDigits: 1 }) : '—'}</td>
              <td className="px-3 py-2.5">{Number(r.fuel_spend) > 0 ? money(Number(r.fuel_spend)) : '—'}</td>
            </tr>
          ))}
        </Table>
      )}
    </Card>
  )
}

export default function Fuel() {
  const { user } = useAuth()
  const isAdmin = user?.role === 'admin'
  const qc = useQueryClient()
  const fileRef = useRef<HTMLInputElement>(null)

  const [start, setStart] = useState(monthStart())
  const [end, setEnd] = useState(isoDate(new Date()))
  const [importResult, setImportResult] = useState<FuelImportResult | null>(null)
  const [pageError, setPageError] = useState('')

  const byTruckQ = useQuery({ queryKey: ['fuel', 'by-truck', start, end], queryFn: () => fuelByTruck(start, end) })
  const iftaQ = useQuery({ queryKey: ['fuel', 'ifta', start, end], queryFn: () => fuelIftaSummary(start, end) })
  const txnsQ = useQuery({ queryKey: ['fuel', 'txns', start, end], queryFn: () => listFuelTransactions({ start, end }) })

  const byTruck = byTruckQ.data ?? []
  const ifta = iftaQ.data ?? []
  const txns = txnsQ.data ?? []

  // Click-to-sort: per-truck rollup (default biggest spender first) and the
  // recent-transactions list (default newest first). nulls-last comparator
  // shape copied from the Invoices receivables list.
  const [truckSort, setTruckSort] = useState<SortState>({ key: 'spend', dir: 'desc' })
  const sortedByTruck = useMemo(() => {
    const val = (r: (typeof byTruck)[number]): unknown => {
      switch (truckSort.key) {
        case 'unit': return r.unit_number
        case 'transactions': return Number(r.transactions)
        case 'gallons': return Number(r.gallons)
        case 'spend': return Number(r.spend)
        default: return null
      }
    }
    const dir = truckSort.dir === 'asc' ? 1 : -1
    // blanks/nulls stay last in BOTH directions (reversing would surface them)
    return [...byTruck].sort((a, b) => {
      const av = val(a), bv = val(b)
      const aNil = av == null || av === ''
      const bNil = bv == null || bv === ''
      if (aNil && bNil) return 0
      if (aNil) return 1
      if (bNil) return -1
      return dir * compareValues(av, bv)
    })
  }, [byTruck, truckSort])

  const [txnSort, setTxnSort] = useState<SortState>({ key: 'date', dir: 'desc' })
  const sortedTxns = useMemo(() => {
    const val = (t: (typeof txns)[number]): unknown => {
      switch (txnSort.key) {
        case 'date': return t.transaction_time ? new Date(t.transaction_time).getTime() : null
        case 'merchant': return t.merchant
        case 'card': return t.card_last_four
        case 'gallons': return t.gallons != null ? Number(t.gallons) : null
        case 'amount': return Number(t.amount)
        case 'net': return t.net_of_discount != null ? Number(t.net_of_discount) : null
        case 'unit': return t.vehicle_name
        case 'driver': return t.driver_name
        case 'status': return t.status
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
  const totalGallons = byTruck.reduce((s, r) => s + Number(r.gallons), 0)
  const totalTxns = byTruck.reduce((s, r) => s + Number(r.transactions), 0)
  const avgPerGal = totalGallons > 0 ? totalSpend / totalGallons : null

  const importMutation = useMutation({
    mutationFn: (csv: string) => importFuelCsv(csv),
    onSuccess: (result) => {
      setPageError('')
      setImportResult(result)
      qc.invalidateQueries({ queryKey: ['fuel'] })
    },
    onError: (err) => {
      setImportResult(null)
      setPageError(errorMessage(err))
    },
  })

  async function onPickFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    // Reset the input so re-picking the same file still fires onChange.
    if (fileRef.current) fileRef.current.value = ''
    if (!file) return
    try {
      const text = await file.text()
      importMutation.mutate(text)
    } catch (err) {
      setImportResult(null)
      setPageError(errorMessage(err))
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <h1 className="text-xl font-bold text-body">Fuel</h1>
        <div className="flex flex-wrap items-end gap-3">
          <Field label="From" className="w-40">
            <Input type="date" value={start} max={end} onChange={(e) => setStart(e.target.value)} />
          </Field>
          <Field label="To" className="w-40">
            <Input type="date" value={end} min={start} onChange={(e) => setEnd(e.target.value)} />
          </Field>
          {isAdmin && (
            <div>
              <input ref={fileRef} type="file" accept=".csv,text/csv" className="hidden" onChange={onPickFile} />
              <Button
                variant="secondary"
                disabled={importMutation.isPending}
                onClick={() => fileRef.current?.click()}
              >
                {importMutation.isPending ? 'Importing…' : '⬆ Import CSV'}
              </Button>
            </div>
          )}
        </div>
      </div>

      {pageError && <p className="rounded-lg bg-red-500/10 p-3 text-sm text-red-600 dark:text-red-300">{pageError}</p>}
      {importResult && (
        <div className="rounded-lg bg-green-500/10 p-3 text-sm text-green-700 dark:text-green-300">
          Imported: {importResult.parsed} parsed · {importResult.inserted} inserted · {importResult.updated} updated
          {importResult.unmatched_trucks > 0 && (
            <> · {importResult.unmatched_trucks} row(s) not matched to a truck (add/rename the truck by its AtoB Vehicle Name, then re-import)</>
          )}
        </div>
      )}

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label="Total Spend" value={money(totalSpend)} icon="⛽" color="green" />
        <StatCard label="Total Gallons" value={totalGallons.toLocaleString(undefined, { maximumFractionDigits: 1 })} icon="🛢️" color="blue" />
        <StatCard label="Avg $/Gal" value={avgPerGal != null ? `$${avgPerGal.toFixed(3)}` : '—'} icon="📈" color="amber" />
        <StatCard label="Transactions" value={totalTxns.toLocaleString()} icon="🧾" color="purple" />
      </div>

      <MpgCard />
      <ReconCard />

      <Card title="Fuel by Truck">
        {byTruckQ.isError ? (
          <LoadError error={byTruckQ.error} onRetry={() => byTruckQ.refetch()} />
        ) : byTruckQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : byTruck.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No fuel spend in this range.</p>
        ) : (
          <Table
            headers={[
              { label: 'Unit', key: 'unit' },
              { label: 'Transactions', key: 'transactions' },
              { label: 'Gallons', key: 'gallons' },
              { label: 'Spend', key: 'spend' },
            ]}
            sort={truckSort}
            onSort={(k) => setTruckSort((p) => toggleSort(p, k))}
          >
            {sortedByTruck.map((r) => (
              <tr key={r.truck_id}>
                <td className="px-3 py-3 font-medium">{r.unit_number}</td>
                <td className="px-3 py-3">{Number(r.transactions).toLocaleString()}</td>
                <td className="px-3 py-3">{Number(r.gallons).toLocaleString(undefined, { maximumFractionDigits: 1 })}</td>
                <td className="px-3 py-3 font-semibold">{money(r.spend)}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <IftaQuarterCard />

      <Card title="IFTA by Jurisdiction">
        {iftaQ.isError ? (
          <LoadError error={iftaQ.error} onRetry={() => iftaQ.refetch()} />
        ) : iftaQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : ifta.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No jurisdiction data in this range.</p>
        ) : (
          <Table headers={['State', 'Gallons', 'Spend', 'Transactions']}>
            {ifta.map((r) => (
              <tr key={r.jurisdiction}>
                <td className="px-3 py-3 font-medium">{r.jurisdiction || '—'}</td>
                <td className="px-3 py-3">{Number(r.gallons).toLocaleString(undefined, { maximumFractionDigits: 1 })}</td>
                <td className="px-3 py-3 font-semibold">{money(r.spend)}</td>
                <td className="px-3 py-3">{Number(r.transactions).toLocaleString()}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Card title="Recent Transactions">
        {txnsQ.isError ? (
          <LoadError error={txnsQ.error} onRetry={() => txnsQ.refetch()} />
        ) : txnsQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : txns.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No transactions in this range.</p>
        ) : (
          <Table
            headers={[
              { label: 'Date', key: 'date' },
              { label: 'Merchant', key: 'merchant' },
              { label: 'Card', key: 'card' },
              { label: 'Gallons', key: 'gallons' },
              { label: 'Amount', key: 'amount' },
              { label: 'Net', key: 'net' },
              { label: 'Unit', key: 'unit' },
              { label: 'Driver', key: 'driver' },
              { label: 'Status', key: 'status' },
            ]}
            sort={txnSort}
            onSort={(k) => setTxnSort((p) => toggleSort(p, k))}
          >
            {sortedTxns.map((t) => (
              <tr key={t.uuid} className="hover:bg-surface-2">
                <td className="px-3 py-3 whitespace-nowrap">{formatDateTime(t.transaction_time)}</td>
                <td className="px-3 py-3">
                  <div className="font-medium">{t.merchant || '—'}</div>
                  {(t.merchant_city || t.merchant_state) && (
                    <div className="text-xs text-muted">
                      {[t.merchant_city, t.merchant_state].filter(Boolean).join(', ')}
                    </div>
                  )}
                </td>
                <td className="px-3 py-3 whitespace-nowrap text-muted">{t.card_last_four ? `•••• ${t.card_last_four}` : '—'}</td>
                <td className="px-3 py-3">{t.gallons != null ? Number(t.gallons).toLocaleString(undefined, { maximumFractionDigits: 1 }) : '—'}</td>
                <td className="px-3 py-3 font-semibold">{money(t.amount)}</td>
                <td className="px-3 py-3">{t.net_of_discount != null ? money(t.net_of_discount) : '—'}</td>
                <td className="px-3 py-3">{t.vehicle_name || '—'}</td>
                <td className="px-3 py-3">{t.driver_name || '—'}</td>
                <td className="px-3 py-3">{t.status ? <Badge status={t.status} /> : '—'}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
    </div>
  )
}

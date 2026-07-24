import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { Button, Card, LoadError, money, Table } from '../components/ui'
import { acctAging, dotAuditPack, glBalanceRatios, glCfoSnapshot, glPnlMonthly, quotePricingReport, stressTest, weeklyFlash } from '../data'

function Kpi({ label, value, note }: { label: string; value: string; note?: string }) {
  return (
    <div className="rounded-xl border border-edge bg-surface p-3">
      <div className="text-[11px] font-semibold uppercase text-muted">{label}</div>
      <div className="mt-0.5 text-xl font-bold text-body">{value}</div>
      {note && <div className="text-[11px] text-muted">{note}</div>}
    </div>
  )
}

/** One printable page for the bank: P&L, ratios, AR, stress verdicts —
 * straight from the QBO-mirrored books, sources footnoted. */
export default function BoardPack() {
  const pnlQ = useQuery({ queryKey: ['board-pnl'], queryFn: () => glPnlMonthly(6), retry: false })
  const cfoQ = useQuery({ queryKey: ['board-cfo'], queryFn: glCfoSnapshot, retry: false })
  const balQ = useQuery({ queryKey: ['board-bal'], queryFn: glBalanceRatios, retry: false })
  const agingQ = useQuery({ queryKey: ['board-aging'], queryFn: acctAging, retry: false })
  const stressQ = useQuery({ queryKey: ['stress-test'], queryFn: stressTest, retry: false })
  // R9 #168: board pack refresh — the ops/safety/pricing picture beside finance.
  const flashQ = useQuery({ queryKey: ['board-flash'], queryFn: () => weeklyFlash(0), retry: false })
  const dotQ = useQuery({ queryKey: ['board-dot'], queryFn: dotAuditPack, retry: false })
  const pricingQ = useQuery({ queryKey: ['board-pricing'], queryFn: () => quotePricingReport(180), retry: false })

  if (pnlQ.isError) return <LoadError error={pnlQ.error} onRetry={() => pnlQ.refetch()} />
  if (!pnlQ.data || !cfoQ.data) return <p className="py-8 text-center text-muted">Assembling the pack…</p>

  const pnl = pnlQ.data
  const cfo = cfoQ.data
  const bal = balQ.data
  const aging = agingQ.data ?? []
  const stress = stressQ.data
  const flash = flashQ.data
  const dot = dotQ.data
  const pricing = pricingQ.data
  const arTotal = aging.reduce((s, r) => s + Number(r.total ?? 0), 0)
  const arLate = aging.reduce((s, r) => s + Number(r.d61_90 ?? 0) + Number(r.d90_plus ?? 0), 0)
  const num = (v: number | null | undefined, d = 2) => (v == null ? '—' : Number(v).toFixed(d))
  // DOT readiness as a single fraction: credential/equipment lines met out of total.
  const dotReady = dot ? (() => {
    const checks: [number, number][] = [
      [dot.cdl_on_file, dot.drivers_active], [dot.medcard_on_file, dot.drivers_active],
      [dot.dqf_complete, dot.drivers_active], [dot.annual_inspection_current, dot.trucks_active],
      [dot.eld_reporting_7d, dot.trucks_active],
    ]
    const met = checks.reduce((s, [h]) => s + h, 0)
    const want = checks.reduce((s, [, w]) => s + w, 0)
    return want > 0 ? Math.round((met / want) * 100) : null
  })() : null

  return (
    <div className="mx-auto max-w-3xl space-y-4 print:max-w-none">
      <div className="flex items-center justify-between print:hidden">
        <Link to="/reports" className="text-sm text-brand hover:underline">← Reports</Link>
        <Button onClick={() => window.print()}>Print / PDF</Button>
      </div>

      <div>
        <h1 className="text-xl font-bold text-body">Aida Logistics LLC — financial pack</h1>
        <p className="text-sm text-muted">
          Prepared {new Date().toLocaleDateString()} · books mirrored from QuickBooks
          {cfo.as_of && ` · balance sheet as of ${new Date(cfo.as_of + 'T00:00:00').toLocaleDateString()}`}
        </p>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Kpi label="Revenue (12 mo)" value={money(cfo.revenue_12m ?? 0)} />
        <Kpi label="EBITDA (12 mo)" value={bal?.ebitda_12m != null ? money(bal.ebitda_12m) : '—'} />
        <Kpi label="Cash" value={money(cfo.cash ?? 0)} note={cfo.days_of_cash != null ? `${num(cfo.days_of_cash, 0)} days of cash` : undefined} />
        <Kpi label="Working capital" value={money(cfo.working_capital ?? 0)} note={cfo.current_ratio != null ? `current ratio ${num(cfo.current_ratio)}` : undefined} />
        <Kpi label="Net debt / EBITDA" value={num(bal?.net_debt_to_ebitda)} note={bal?.net_debt != null ? `net debt ${money(bal.net_debt)}` : undefined} />
        <Kpi label="Debt / equity" value={num(bal?.debt_to_equity)} note={bal?.leverage != null ? `leverage ${num(bal.leverage)}x` : undefined} />
        <Kpi label="Interest coverage" value={num(cfo.interest_coverage, 1)} />
        <Kpi label="Open AR" value={money(arTotal)} note={arLate > 0 ? `${money(arLate)} over 60 days` : 'nothing over 60 days'} />
      </div>

      <Card title="P&L — last 6 months (from the books)">
        <Table headers={['Month', 'Income', 'Gross margin', 'Net income', 'Net %', 'OR']}>
          {pnl.map((m) => (
            <tr key={m.month}>
              <td className="px-3 py-2 font-medium">{m.month}</td>
              <td className="px-3 py-2">{money(Number(m.income))}</td>
              <td className="px-3 py-2 text-muted">{m.gross_margin_pct != null ? `${m.gross_margin_pct}%` : '—'}</td>
              <td className={`px-3 py-2 font-semibold ${Number(m.net_income) < 0 ? 'text-red-600' : ''}`}>{money(Number(m.net_income))}</td>
              <td className="px-3 py-2 text-muted">{m.net_margin_pct != null ? `${m.net_margin_pct}%` : '—'}</td>
              <td className="px-3 py-2 text-muted">{m.operating_ratio ?? '—'}</td>
            </tr>
          ))}
        </Table>
      </Card>

      {stress && (
        <Card title="Stress resilience (GL trailing-3-month cost structure)">
          <ul className="space-y-1 text-sm">
            <li>Diesel +40%: monthly net {money(Number(stress.fuel_up_40.shocked.monthly_net))} — {stress.fuel_up_40.survives ? 'survives' : 'at risk'}</li>
            <li>Revenue −25%: monthly net {money(Number(stress.revenue_down_25.shocked.monthly_net))} — {stress.revenue_down_25.survives ? 'survives' : 'at risk'}</li>
            <li>Insurance +30%: monthly net {money(Number(stress.insurance_up_30.shocked.monthly_net))} — {stress.insurance_up_30.survives ? 'survives' : 'at risk'}</li>
            <li>All three at once: monthly net {money(Number(stress.perfect_storm.shocked.monthly_net))} — {stress.perfect_storm.survives ? 'survives' : 'the margin, not the bank account, is the cushion'}</li>
          </ul>
        </Card>
      )}

      {(flash || dot) && (
        <Card title="Operations & safety (this week / current)">
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Kpi label="Loads (wk)" value={flash?.ops.loads != null ? String(flash.ops.loads) : '—'} />
            <Kpi label="On-time" value={flash?.ops.on_time_pct != null ? `${flash.ops.on_time_pct}%` : '—'} />
            <Kpi label="Detention (wk)" value={flash?.ops.detention_hours != null ? `${num(flash.ops.detention_hours, 1)} h` : '—'}
              note={flash?.ops.detention_billable != null ? `${money(flash.ops.detention_billable)} billable` : undefined} />
            <Kpi label="Open alerts" value={flash ? String(flash.sentinel.open) : '—'}
              note={flash && flash.sentinel.critical > 0 ? `${flash.sentinel.critical} critical` : undefined} />
            <Kpi label="DOT readiness" value={dotReady != null ? `${dotReady}%` : '—'}
              note={dot ? `${dot.drivers_active} drivers · ${dot.trucks_active} trucks` : undefined} />
            <Kpi label="CDL current" value={dot ? `${dot.cdl_on_file}/${dot.drivers_active}` : '—'}
              note={dot && dot.cdl_expired.length > 0 ? `${dot.cdl_expired.length} expired` : undefined} />
            <Kpi label="Med cards" value={dot ? `${dot.medcard_on_file}/${dot.drivers_active}` : '—'} />
            <Kpi label="Safety events (365d)" value={dot ? String(dot.safety_events_365d) : '—'} />
          </div>
        </Card>
      )}

      {pricing && pricing.decided > 0 && (
        <Card title="Pricing discipline (quotes, 180 days)">
          <p className="text-sm text-body">
            {pricing.won.avg_premium_pct != null && <>Won quotes averaged <span className="font-semibold">{pricing.won.avg_premium_pct > 0 ? '+' : ''}{pricing.won.avg_premium_pct}%</span> vs our own lane book ({pricing.won.n}). </>}
            {pricing.lost.avg_premium_pct != null && <>Lost quotes averaged <span className="font-semibold">{pricing.lost.avg_premium_pct > 0 ? '+' : ''}{pricing.lost.avg_premium_pct}%</span> ({pricing.lost.n}) — the price the market walked from.</>}
          </p>
          {pricing.lost.top_reasons.length > 0 && (
            <p className="mt-1 text-xs text-muted">Loss reasons: {pricing.lost.top_reasons.map((r) => `${r.reason} (${r.n})`).join(' · ')}</p>
          )}
          <p className="mt-1 text-[11px] text-muted">Premium is vs our own booked lane average, not a market index we don't hold.</p>
        </Card>
      )}

      <p className="text-[11px] text-muted">
        Sources: QuickBooks GL mirror (30-min sync), balance-sheet snapshot, receivables ledger, GL-anchored
        stress model (assumptions embedded in each scenario), weekly ops flash, DOT credential ledger, and the
        quote-pricing feedback loop. Generated by Truxon.
      </p>
    </div>
  )
}

/** Accounting — the money command center. Truxon as the complete billing
 * system: invoicing, emailing invoices to brokers, payment recording (checks/
 * ACH/factoring, partials), receivables with paid/unpaid/past-due toggles,
 * DSO, per-customer aging, unbilled-load leak detection, and revenue/margin
 * reports. QuickBooks stays an optional mirror (QBO-badged rows), not a
 * dependency. */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { Area, AreaChart, Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { Badge, Button, Card, Field, formatDate, LoadError, Modal, money, Select, Table } from '../components/ui'
import {
  acctAging, acctMarginMonthly, acctRevenueByCustomer, acctRevenueMonthly, acctSummary, acctUnbilledLoads,
  cashflowForecast, createInvoice, deleteInvoicePayment, emailInvoice, glBreakevenMonthly, glCfoSnapshot, glExpenseBreakdown,
  glPnlMonthly, listCustomers, listInvoicePayments, listInvoices, listLoads,
  qboConnectUrl, qboStatus, recordInvoicePayment, revenueForecast, setInvoiceStatus, slowPayRisk, triggerQboPull, voidInvoice,
} from '../data'
import { downloadInvoicePdf, invoicePdfBase64 } from '../invoicePdf'
import { errorMessage } from '../supabase'
import type { Invoice } from '../types'

type Tab = 'overview' | 'receivables' | 'aging' | 'unbilled' | 'forecast' | 'reports'
type Filter = 'all' | 'unpaid' | 'pastdue' | 'paid' | 'draft' | 'void'

const TABS: { key: Tab; label: string }[] = [
  { key: 'overview', label: 'Overview' },
  { key: 'receivables', label: 'Receivables' },
  { key: 'aging', label: 'Aging' },
  { key: 'unbilled', label: 'Unbilled' },
  { key: 'forecast', label: '🔮 Forecast' },
  { key: 'reports', label: 'Reports' },
]

const FILTERS: { key: Filter; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'unpaid', label: 'Unpaid' },
  { key: 'pastdue', label: 'Past due' },
  { key: 'paid', label: 'Paid' },
  { key: 'draft', label: 'Draft' },
  { key: 'void', label: 'Void' },
]

const isPastDue = (inv: Invoice) => inv.status === 'sent' && !!inv.due_date && new Date(inv.due_date) < new Date()
const daysOverdue = (inv: Invoice) => Math.floor((Date.now() - new Date(inv.due_date!).getTime()) / 86_400_000)

/** QuickBooks mirror card (optional — Truxon works fully without it). */
function QboPanel() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['qbo-status'], queryFn: qboStatus, retry: false, refetchInterval: 120_000 })
  const pull = useMutation({
    mutationFn: triggerQboPull,
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['qbo-status'] })
      qc.invalidateQueries({ queryKey: ['invoices'] })
    },
  })
  if (!q.data) return null
  const s = q.data

  async function connect() {
    window.open(await qboConnectUrl(), '_blank', 'noopener')
  }

  return (
    <div className="mb-4 flex flex-wrap items-center gap-3 rounded-2xl border border-line bg-surface p-3 text-sm">
      <span className="font-semibold text-body">🧾 QuickBooks</span>
      {s.connected ? (
        <>
          <span className="rounded bg-green-500/15 px-1.5 py-0.5 text-xs font-semibold text-green-700 dark:text-green-300">Connected</span>
          <span className="text-muted">
            {s.qbo_invoices} invoices mirrored · {money(s.qbo_open_balance)} open
            {s.last_pull_at && <> · synced {formatDate(s.last_pull_at)}</>}
          </span>
          {s.last_error && <span className="text-xs text-red-600 dark:text-red-300">⚠ {s.last_error.slice(0, 120)}</span>}
          <button
            onClick={() => pull.mutate()}
            disabled={pull.isPending}
            className="ml-auto rounded-lg border border-line px-2.5 py-1 text-xs font-medium text-muted hover:text-body disabled:opacity-50"
          >
            {pull.isPending ? 'Syncing…' : 'Sync now'}
          </button>
        </>
      ) : (
        <>
          <span className="text-muted">Optional: mirror your QBO invoices during the transition.</span>
          <Button onClick={connect}>Connect QuickBooks</Button>
        </>
      )}
    </div>
  )
}

function Kpi({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: 'bad' | 'warn' | 'good' }) {
  const toneCls = tone === 'bad' ? 'text-red-600 dark:text-red-300' : tone === 'warn' ? 'text-amber-600 dark:text-amber-300' : tone === 'good' ? 'text-green-600 dark:text-green-300' : 'text-body'
  return (
    <div className="rounded-2xl border border-line bg-surface p-4">
      <div className="text-xs font-medium text-muted uppercase">{label}</div>
      <div className={`mt-1 text-2xl font-bold ${toneCls}`}>{value}</div>
      {sub && <div className="text-xs text-muted">{sub}</div>}
    </div>
  )
}

export default function Invoices() {
  const qc = useQueryClient()
  const [tab, setTab] = useState<Tab>('overview')
  const [filter, setFilter] = useState<Filter>('unpaid')
  const [search, setSearch] = useState('')
  const [creating, setCreating] = useState(false)
  const [customerId, setCustomerId] = useState('')
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const [error, setError] = useState('')
  const [pageError, setPageError] = useState('')
  const [payFor, setPayFor] = useState<Invoice | null>(null)
  const [emailFor, setEmailFor] = useState<Invoice | null>(null)

  const invoicesQ = useQuery({ queryKey: ['invoices'], queryFn: listInvoices })
  const invoices = invoicesQ.data ?? []
  const summaryQ = useQuery({ queryKey: ['acct-summary'], queryFn: acctSummary, retry: false })
  const customersQ = useQuery({ queryKey: ['customers', ''], queryFn: () => listCustomers() })
  const customers = customersQ.data ?? []
  const { data: billableLoads = [] } = useQuery({
    queryKey: ['loads', 'completed', customerId],
    queryFn: () => listLoads({ status: 'completed', customer_id: customerId }),
    enabled: creating && !!customerId,
  })

  const create = useMutation({
    mutationFn: () => createInvoice(Number(customerId), [...selected]),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['invoices'] })
      qc.invalidateQueries({ queryKey: ['loads'] })
      qc.invalidateQueries({ queryKey: ['acct-summary'] })
      qc.invalidateQueries({ queryKey: ['acct-unbilled'] })
      closeCreate()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  const statusMutation = useMutation({
    mutationFn: ({ id, status }: { id: number; status: string }) => setInvoiceStatus(id, status),
    onSuccess: () => {
      setPageError('')
      qc.invalidateQueries({ queryKey: ['invoices'] })
      qc.invalidateQueries({ queryKey: ['acct-summary'] })
    },
    onError: (err) => setPageError(errorMessage(err)),
  })

  const voidMutation = useMutation({
    mutationFn: (id: number) => voidInvoice(id),
    onSuccess: () => {
      setPageError('')
      qc.invalidateQueries({ queryKey: ['invoices'] })
      qc.invalidateQueries({ queryKey: ['loads'] })
      qc.invalidateQueries({ queryKey: ['acct-summary'] })
    },
    onError: (err) => setPageError(errorMessage(err)),
  })

  function pdf(id: number) {
    downloadInvoicePdf(id).catch((err) => setPageError(errorMessage(err)))
  }

  function closeCreate() {
    setCreating(false)
    setCustomerId('')
    setSelected(new Set())
    setError('')
  }

  function toggle(id: number) {
    const next = new Set(selected)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    setSelected(next)
  }

  function billCustomer(cid: number) {
    setCustomerId(String(cid))
    setCreating(true)
    setTab('receivables')
  }

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return invoices.filter((inv) => {
      if (filter === 'unpaid' && inv.status !== 'sent') return false
      if (filter === 'pastdue' && !isPastDue(inv)) return false
      if (filter === 'paid' && inv.status !== 'paid') return false
      if (filter === 'draft' && inv.status !== 'draft') return false
      if (filter === 'void' && inv.status !== 'void') return false
      if (q) {
        const hay = `${inv.invoice_number} ${inv.qbo_doc_number ?? ''} ${inv.customer_name ?? ''}`.toLowerCase()
        if (!hay.includes(q)) return false
      }
      return true
    })
  }, [invoices, filter, search])

  const filteredTotal = filtered.reduce((s, i) => s + Number(i.total), 0)
  const filterCount = (f: Filter) =>
    invoices.filter((inv) =>
      f === 'all' ? true
      : f === 'unpaid' ? inv.status === 'sent'
      : f === 'pastdue' ? isPastDue(inv)
      : inv.status === f).length

  const total = billableLoads.filter((l) => selected.has(l.id)).reduce((sum, l) => sum + Number(l.rate), 0)
  const s = summaryQ.data

  return (
    <Card
      title="Accounting"
      actions={<Button onClick={() => setCreating(true)}>+ Generate Invoice</Button>}
    >
      <QboPanel />
      {pageError && <p className="mb-3 rounded-lg bg-red-500/10 p-3 text-sm text-red-600 dark:text-red-300">{pageError}</p>}

      <div className="mb-4 flex gap-1 overflow-x-auto rounded-xl border border-line bg-surface-2 p-1">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`rounded-lg px-3 py-1.5 text-sm font-medium whitespace-nowrap ${tab === t.key ? 'bg-surface text-body shadow' : 'text-muted hover:text-body'}`}
          >
            {t.label}
            {t.key === 'unbilled' && (s?.unbilled_count ?? 0) > 0 && (
              <span className="ml-1.5 rounded-full bg-amber-500/20 px-1.5 text-xs font-semibold text-amber-700 dark:text-amber-300">{s!.unbilled_count}</span>
            )}
          </button>
        ))}
      </div>

      {/* ── Overview ── */}
      {tab === 'overview' && (
        s ? (
          <div className="space-y-4">
            <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
              <Kpi label="Receivables" value={money(s.ar_total)} sub={`${s.open_count} open invoices`} />
              <Kpi label="Past due" value={money(s.ar_past_due)} sub={`${s.past_due_count} invoices`} tone={s.ar_past_due > 0 ? 'bad' : 'good'} />
              <Kpi label="DSO" value={s.dso != null ? `${s.dso}d` : '—'} sub="90-day standard" tone={s.dso != null && s.dso > 45 ? 'warn' : undefined} />
              <Kpi label="Unbilled loads" value={money(s.unbilled_total)} sub={`${s.unbilled_count} loads not invoiced`} tone={s.unbilled_count > 0 ? 'warn' : 'good'} />
              <Kpi label="Billed MTD" value={money(s.mtd_billed)} />
              <Kpi label="Collected MTD" value={money(s.mtd_collected)} sub={s.avg_days_to_pay != null ? `avg ${s.avg_days_to_pay}d to pay` : undefined} />
            </div>
            <OverviewCharts />
          </div>
        ) : summaryQ.isError ? (
          <LoadError error={summaryQ.error} onRetry={() => summaryQ.refetch()} />
        ) : <p className="py-8 text-center text-muted">Loading…</p>
      )}

      {/* ── Receivables ── */}
      {tab === 'receivables' && (
        <>
          <div className="mb-3 flex flex-wrap items-center gap-2">
            {FILTERS.map((f) => (
              <button
                key={f.key}
                onClick={() => setFilter(f.key)}
                className={`rounded-full border px-3 py-1 text-xs font-medium ${filter === f.key ? 'border-brand bg-brand/10 text-brand' : 'border-line text-muted hover:text-body'}`}
              >
                {f.label} <span className="opacity-60">{filterCount(f.key)}</span>
              </button>
            ))}
            <input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search # or customer…"
              className="ml-auto w-52 rounded-lg border border-line bg-surface px-3 py-1.5 text-sm"
            />
          </div>
          {invoicesQ.isLoading ? (
            <p className="py-8 text-center text-muted">Loading…</p>
          ) : invoicesQ.isError ? (
            <LoadError error={invoicesQ.error} onRetry={() => invoicesQ.refetch()} />
          ) : filtered.length === 0 ? (
            <p className="py-8 text-center text-muted">Nothing here — try another filter.</p>
          ) : (
            <>
              <Table headers={['Invoice #', 'Customer', 'Date', 'Due', 'Total', 'Status', '']}>
                {filtered.map((inv) => (
                  <tr key={inv.id} className="hover:bg-surface-2">
                    <td className="px-3 py-3 font-medium text-brand">
                      {inv.source === 'qbo' ? `#${inv.qbo_doc_number}` : inv.invoice_number}
                      {inv.source === 'qbo' && (
                        <span className="ml-2 rounded bg-indigo-500/15 px-1.5 py-0.5 text-xs font-semibold text-indigo-600 dark:text-indigo-300">QBO</span>
                      )}
                    </td>
                    <td className="px-3 py-3">{inv.customer_name}</td>
                    <td className="px-3 py-3">{formatDate(inv.invoice_date)}</td>
                    <td className="px-3 py-3 whitespace-nowrap">
                      {inv.due_date ? formatDate(inv.due_date) : '—'}
                      {isPastDue(inv) && (
                        <span className="ml-1.5 rounded bg-red-500/15 px-1.5 py-0.5 text-xs font-semibold text-red-600 dark:text-red-300">
                          {daysOverdue(inv)}d late
                        </span>
                      )}
                    </td>
                    <td className="px-3 py-3 font-semibold">
                      {money(inv.total)}
                      {inv.source === 'qbo' && inv.status === 'sent' && (inv.qbo_balance ?? 0) < inv.total && (
                        <div className="text-xs font-normal text-muted">{money(inv.qbo_balance ?? 0)} due</div>
                      )}
                    </td>
                    <td className="px-3 py-3"><Badge status={inv.status} /></td>
                    {inv.source === 'qbo' ? (
                      <td className="px-3 py-3 text-right text-xs whitespace-nowrap text-muted">synced from QuickBooks</td>
                    ) : (
                      <td className="px-3 py-3 text-right whitespace-nowrap">
                        <button onClick={() => pdf(inv.id)} className="mr-3 text-sm font-medium text-brand hover:underline">PDF</button>
                        {inv.status !== 'void' && (
                          <button onClick={() => setEmailFor(inv)} className="mr-3 text-sm font-medium text-blue-600 hover:underline" title={inv.sent_at ? `Sent ${formatDate(inv.sent_at)} to ${inv.sent_to}` : 'Email to customer'}>
                            {inv.sent_at ? 'Re-send' : 'Email'}
                          </button>
                        )}
                        {inv.status === 'sent' && (
                          <button onClick={() => setPayFor(inv)} className="mr-3 text-sm font-medium text-green-600 hover:underline">
                            Record payment
                          </button>
                        )}
                        {inv.status === 'draft' && (
                          <button onClick={() => statusMutation.mutate({ id: inv.id, status: 'sent' })} className="mr-3 text-sm font-medium text-blue-600 hover:underline">
                            Mark Sent
                          </button>
                        )}
                        {inv.status !== 'paid' && inv.status !== 'void' && (
                          <button
                            onClick={() => window.confirm(`Void ${inv.invoice_number}? Its loads go back to "completed" for re-billing.`) && voidMutation.mutate(inv.id)}
                            className="text-sm font-medium text-red-600 hover:underline"
                          >
                            Void
                          </button>
                        )}
                      </td>
                    )}
                  </tr>
                ))}
              </Table>
              <p className="mt-2 text-right text-sm text-muted">
                {filtered.length} invoices · <span className="font-semibold text-body">{money(filteredTotal)}</span>
              </p>
            </>
          )}
        </>
      )}

      {tab === 'aging' && <AgingTab />}
      {tab === 'unbilled' && <UnbilledTab onBill={billCustomer} />}
      {tab === 'forecast' && <ForecastTab />}
      {tab === 'reports' && <ReportsTab />}

      {/* ── Generate invoice ── */}
      <Modal title="Generate Invoice" open={creating} onClose={closeCreate}>
        <div className="space-y-4">
          {error && <p className="rounded-lg bg-red-500/10 p-3 text-sm text-red-600 dark:text-red-300">{error}</p>}
          <Field label="Customer">
            <Select value={customerId} onChange={(e) => { setCustomerId(e.target.value); setSelected(new Set()) }}>
              <option value="">Select customer…</option>
              {customers.map((c) => <option key={c.id} value={c.id}>{c.company_name}</option>)}
            </Select>
          </Field>
          {customerId && (
            billableLoads.length === 0 ? (
              <p className="text-sm text-muted">No completed unbilled loads for this customer.</p>
            ) : (
              <div className="max-h-64 space-y-1 overflow-y-auto">
                {billableLoads.map((l) => (
                  <label key={l.id} className="flex items-center gap-3 rounded-lg border border-line p-2 text-sm">
                    <input type="checkbox" checked={selected.has(l.id)} onChange={() => toggle(l.id)} />
                    <span className="font-medium">{l.load_number}</span>
                    <span className="flex-1 truncate text-muted">{l.delivery_address}</span>
                    <span className="font-semibold">{money(Number(l.rate))}</span>
                  </label>
                ))}
              </div>
            )
          )}
          {selected.size > 0 && (
            <p className="text-right text-sm">
              {selected.size} loads · <span className="font-bold">{money(total)}</span>
            </p>
          )}
          <div className="flex justify-end gap-2">
            <Button variant="secondary" onClick={closeCreate}>Cancel</Button>
            <Button onClick={() => create.mutate()} disabled={!customerId || selected.size === 0 || create.isPending}>
              {create.isPending ? 'Creating…' : 'Create Invoice'}
            </Button>
          </div>
        </div>
      </Modal>

      {payFor && <PaymentModal invoice={payFor} onClose={() => setPayFor(null)} />}
      {emailFor && <EmailModal invoice={emailFor} onClose={() => setEmailFor(null)} />}
    </Card>
  )
}

// ── Overview charts ──────────────────────────────────────────────────────────
function OverviewCharts() {
  const revQ = useQuery({ queryKey: ['acct-revenue'], queryFn: () => acctRevenueMonthly(12), retry: false })
  const rows = (revQ.data ?? []).map((r) => ({ ...r, billed: Number(r.billed), collected: Number(r.collected) }))
  if (rows.length === 0) return null
  return (
    <div className="rounded-2xl border border-line bg-surface p-4">
      <h3 className="mb-2 text-sm font-semibold text-body">Billed vs collected — last 12 months</h3>
      <ResponsiveContainer width="100%" height={240}>
        <AreaChart data={rows}>
          <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
          <XAxis dataKey="month" tick={{ fontSize: 11 }} />
          <YAxis tick={{ fontSize: 11 }} tickFormatter={(v: number) => `$${(v / 1000).toFixed(0)}k`} />
          <Tooltip formatter={(v) => money(Number(v))} />
          <Area type="monotone" dataKey="billed" name="Billed" stroke="#2563eb" fill="#2563eb22" />
          <Area type="monotone" dataKey="collected" name="Collected" stroke="#16a34a" fill="#16a34a22" />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  )
}

// ── Aging ────────────────────────────────────────────────────────────────────
// ---------- Forecast (Northstar predictive) ----------
function ForecastTab() {
  const cfQ = useQuery({ queryKey: ['cashflow-forecast'], queryFn: () => cashflowForecast(8), retry: false })
  const spQ = useQuery({ queryKey: ['slow-pay-risk'], queryFn: slowPayRisk, retry: false })
  const rvQ = useQuery({ queryKey: ['revenue-forecast'], queryFn: () => revenueForecast(6), retry: false })
  const weeks = cfQ.data ?? []
  const outlook = rvQ.data ?? []
  const risky = (spQ.data ?? []).filter((r) => r.risk !== 'low')
  const chart = weeks.map((w) => ({ label: `W${w.week_number}`, In: w.expected_in, Out: -w.expected_out, Net: w.net, Running: w.cumulative_net }))
  const riskColor = (r: string) => (r === 'high' ? 'text-red-600 dark:text-red-400' : 'text-amber-600 dark:text-amber-400')

  return (
    <div className="space-y-4">
      <Card title="Cash-flow forecast — next 8 weeks">
        <p className="mb-3 text-xs text-muted">
          Money <strong>in</strong> is projected from each broker's learned pay behavior + delivered-but-unbilled loads; money <strong>out</strong> is your trailing 8-week average (fuel + driver pay + truck fixed). A transparent estimate, not a guarantee.
        </p>
        {cfQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : cfQ.isError ? (
          <LoadError error={cfQ.error} onRetry={() => cfQ.refetch()} />
        ) : (
          <>
            <ResponsiveContainer width="100%" height={240}>
              <BarChart data={chart}>
                <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
                <XAxis dataKey="label" tick={{ fontSize: 12, fill: 'var(--muted)' }} tickLine={false} axisLine={false} />
                <YAxis tick={{ fontSize: 12, fill: 'var(--muted)' }} tickLine={false} axisLine={false} tickFormatter={(v) => `$${(v / 1000).toFixed(0)}k`} />
                <Tooltip formatter={(v) => money(Math.abs(Number(v)))} />
                <Bar dataKey="In" fill="#16a34a" radius={[4, 4, 0, 0]} maxBarSize={28} />
                <Bar dataKey="Out" fill="#dc2626" radius={[0, 0, 4, 4]} maxBarSize={28} />
              </BarChart>
            </ResponsiveContainer>
            <Table headers={['Week', 'Expected in', 'Expected out', 'Net', 'Running']}>
              {weeks.map((w) => (
                <tr key={w.week_start} className="border-b border-line">
                  <td className="px-3 py-2 font-medium">{w.week_label}</td>
                  <td className="px-3 py-2 text-green-600 dark:text-green-400">{money(w.expected_in)}</td>
                  <td className="px-3 py-2 text-red-600 dark:text-red-400">{money(w.expected_out)}</td>
                  <td className={`px-3 py-2 font-medium ${w.net >= 0 ? 'text-body' : 'text-red-600 dark:text-red-400'}`}>{money(w.net)}</td>
                  <td className={`px-3 py-2 font-semibold ${w.cumulative_net >= 0 ? 'text-body' : 'text-red-600 dark:text-red-400'}`}>{money(w.cumulative_net)}</td>
                </tr>
              ))}
            </Table>
          </>
        )}
      </Card>

      <Card title="Revenue outlook — next 6 weeks">
        <p className="mb-3 text-xs text-muted">
          Trailing 8-week average, blended with the <strong>same week last year</strong> where we have the history — so a seasonal dip or bump is expected, not a shock.
        </p>
        {rvQ.isLoading ? (
          <p className="py-6 text-center text-muted">Loading…</p>
        ) : rvQ.isError ? (
          <LoadError error={rvQ.error} onRetry={() => rvQ.refetch()} />
        ) : (
          <Table headers={['Week', 'Forecast', 'Trailing avg', 'Same wk last yr', 'Loads/truck', 'Basis']}>
            {outlook.map((w) => (
              <tr key={w.week_start} className="border-b border-line">
                <td className="px-3 py-2 font-medium">{w.week_label}</td>
                <td className="px-3 py-2 font-semibold text-body">{money(w.forecast_revenue)}</td>
                <td className="px-3 py-2 text-muted">{money(w.trailing_avg)}</td>
                <td className="px-3 py-2 text-muted">{w.last_year_revenue != null ? money(w.last_year_revenue) : '—'}</td>
                <td className="px-3 py-2 text-muted">{w.loads_per_truck ?? '—'}</td>
                <td className="px-3 py-2 text-xs text-muted">{w.basis}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Card title={`Collections risk — invoices predicted to pay late (${risky.length})`}>
        {spQ.isLoading ? (
          <p className="py-6 text-center text-muted">Loading…</p>
        ) : risky.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No open invoices are trending late. 🎉</p>
        ) : (
          <Table headers={['Invoice', 'Customer', 'Amount', 'Pays ~', 'Days late', 'Risk']}>
            {risky.map((r) => (
              <tr key={r.invoice_id} className="border-b border-line">
                <td className="px-3 py-2 font-medium text-brand">{r.invoice_number}</td>
                <td className="px-3 py-2">{r.customer}</td>
                <td className="px-3 py-2">{money(r.total)}</td>
                <td className="px-3 py-2 text-muted">{formatDate(r.predicted_pay_date)}</td>
                <td className={`px-3 py-2 font-medium ${riskColor(r.risk)}`}>{r.predicted_days_late > 0 ? `+${r.predicted_days_late}d` : 'on time'}</td>
                <td className={`px-3 py-2 font-semibold capitalize ${riskColor(r.risk)}`}>{r.risk}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
    </div>
  )
}

function AgingTab() {
  const q = useQuery({ queryKey: ['acct-aging'], queryFn: acctAging, retry: false })
  if (q.isLoading) return <p className="py-8 text-center text-muted">Loading…</p>
  if (q.isError) return <LoadError error={q.error} onRetry={() => q.refetch()} />
  const rows = q.data ?? []
  if (rows.length === 0) return <p className="py-8 text-center text-muted">No open receivables. 🎉</p>
  const sum = (k: keyof typeof rows[0]) => rows.reduce((s, r) => s + Number(r[k] ?? 0), 0)
  return (
    <Table headers={['Customer', 'Current', '1–30', '31–60', '61–90', '90+', 'Total', 'Inv.']}>
      {rows.map((r) => (
        <tr key={r.customer_id} className="hover:bg-surface-2">
          <td className="px-3 py-2.5 font-medium">{r.customer_name}</td>
          <td className="px-3 py-2.5">{Number(r.current_due) > 0 ? money(Number(r.current_due)) : '—'}</td>
          <td className="px-3 py-2.5">{Number(r.d1_30) > 0 ? <span className="text-amber-700 dark:text-amber-300">{money(Number(r.d1_30))}</span> : '—'}</td>
          <td className="px-3 py-2.5">{Number(r.d31_60) > 0 ? <span className="text-amber-700 dark:text-amber-300">{money(Number(r.d31_60))}</span> : '—'}</td>
          <td className="px-3 py-2.5">{Number(r.d61_90) > 0 ? <span className="text-red-600 dark:text-red-300">{money(Number(r.d61_90))}</span> : '—'}</td>
          <td className="px-3 py-2.5">{Number(r.d90_plus) > 0 ? <span className="font-semibold text-red-600 dark:text-red-300">{money(Number(r.d90_plus))}</span> : '—'}</td>
          <td className="px-3 py-2.5 font-semibold">{money(Number(r.total))}</td>
          <td className="px-3 py-2.5 text-muted">{r.invoice_count}</td>
        </tr>
      ))}
      <tr className="border-t-2 border-line bg-surface-2 font-semibold">
        <td className="px-3 py-2.5">Total</td>
        <td className="px-3 py-2.5">{money(sum('current_due'))}</td>
        <td className="px-3 py-2.5">{money(sum('d1_30'))}</td>
        <td className="px-3 py-2.5">{money(sum('d31_60'))}</td>
        <td className="px-3 py-2.5">{money(sum('d61_90'))}</td>
        <td className="px-3 py-2.5">{money(sum('d90_plus'))}</td>
        <td className="px-3 py-2.5">{money(sum('total'))}</td>
        <td className="px-3 py-2.5" />
      </tr>
    </Table>
  )
}

// ── Unbilled loads ───────────────────────────────────────────────────────────
function UnbilledTab({ onBill }: { onBill: (customerId: number) => void }) {
  const q = useQuery({ queryKey: ['acct-unbilled'], queryFn: acctUnbilledLoads, retry: false })
  if (q.isLoading) return <p className="py-8 text-center text-muted">Loading…</p>
  if (q.isError) return <LoadError error={q.error} onRetry={() => q.refetch()} />
  const rows = q.data ?? []
  if (rows.length === 0) return <p className="py-8 text-center text-muted">Every completed load is invoiced. 🎉</p>
  const totalLeak = rows.reduce((s, r) => s + Number(r.rate), 0)
  return (
    <>
      <p className="mb-3 rounded-lg bg-amber-500/10 p-3 text-sm text-amber-800 dark:text-amber-200">
        <strong>{money(totalLeak)}</strong> delivered but not invoiced — every day unbilled is a free loan to the broker.
      </p>
      <Table headers={['Load #', 'Customer', 'Delivered', 'Days unbilled', 'Rate', '']}>
        {rows.map((r) => (
          <tr key={r.load_id} className="hover:bg-surface-2">
            <td className="px-3 py-2.5 font-medium text-brand">{r.load_number}</td>
            <td className="px-3 py-2.5">{r.customer_name}</td>
            <td className="px-3 py-2.5">{r.delivered_at ? formatDate(r.delivered_at) : '—'}</td>
            <td className="px-3 py-2.5">
              <span className={Number(r.days_unbilled) > 7 ? 'font-semibold text-red-600 dark:text-red-300' : Number(r.days_unbilled) > 3 ? 'text-amber-700 dark:text-amber-300' : ''}>
                {r.days_unbilled}d
              </span>
            </td>
            <td className="px-3 py-2.5 font-semibold">{money(Number(r.rate))}</td>
            <td className="px-3 py-2.5 text-right">
              <button onClick={() => onBill(r.customer_id)} className="text-sm font-medium text-brand hover:underline">Bill now</button>
            </td>
          </tr>
        ))}
      </Table>
    </>
  )
}

// ── GL section: the full picture from the books ─────────────────────────────
function GlSection() {
  const pnlQ = useQuery({ queryKey: ['gl-pnl'], queryFn: () => glPnlMonthly(12), retry: false })
  const cfoQ = useQuery({ queryKey: ['gl-cfo'], queryFn: glCfoSnapshot, retry: false })
  const expQ = useQuery({ queryKey: ['gl-exp'], queryFn: () => glExpenseBreakdown(6), retry: false })
  const beQ = useQuery({ queryKey: ['gl-be'], queryFn: () => glBreakevenMonthly(6), retry: false })
  const pnl = (pnlQ.data ?? []).map((m) => ({ ...m, income: Number(m.income), net_income: Number(m.net_income) }))
  if (pnl.length === 0) return null // GL mirror not synced yet
  const cfo = cfoQ.data
  const latest = pnl[pnl.length - 1]
  const exp = (expQ.data ?? []).slice(0, 12)
  const be = (beQ.data ?? []).filter((b) => b.rpm_breakeven != null)

  return (
    <div className="space-y-4">
      <h3 className="text-sm font-semibold text-body">📚 From the books — full P&L (GL mirror, refreshed nightly)</h3>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        <Kpi label="Operating ratio" value={latest?.operating_ratio != null ? `${latest.operating_ratio}%` : '—'}
          sub={`${latest?.month} · target <95%`} tone={latest?.operating_ratio != null ? (Number(latest.operating_ratio) > 95 ? 'bad' : 'good') : undefined} />
        <Kpi label="Net margin" value={latest?.net_margin_pct != null ? `${latest.net_margin_pct}%` : '—'} sub={latest?.month} />
        {cfo?.cash != null && <Kpi label="Cash on hand" value={money(Number(cfo.cash))} sub={cfo.days_of_cash != null ? `${cfo.days_of_cash} days of cost` : undefined} />}
        {cfo?.current_ratio != null && <Kpi label="Current ratio" value={String(cfo.current_ratio)} tone={Number(cfo.current_ratio) < 1 ? 'bad' : 'good'} />}
        {cfo?.dpo != null && <Kpi label="DPO" value={`${cfo.dpo}d`} sub="days payable outstanding" />}
        {cfo?.overhead_per_tractor_month != null && <Kpi label="Overhead / tractor" value={money(Number(cfo.overhead_per_tractor_month))} sub="per month" />}
      </div>
      <div className="rounded-2xl border border-line bg-surface p-4">
        <h4 className="mb-2 text-sm font-semibold text-body">Revenue vs net income (all costs)</h4>
        <ResponsiveContainer width="100%" height={220}>
          <AreaChart data={pnl}>
            <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
            <XAxis dataKey="month" tick={{ fontSize: 11 }} />
            <YAxis tick={{ fontSize: 11 }} tickFormatter={(v: number) => `$${(v / 1000).toFixed(0)}k`} />
            <Tooltip formatter={(v) => money(Number(v))} />
            <Area type="monotone" dataKey="income" name="Revenue" stroke="#2563eb" fill="#2563eb22" />
            <Area type="monotone" dataKey="net_income" name="Net income" stroke="#16a34a" fill="#16a34a22" />
          </AreaChart>
        </ResponsiveContainer>
      </div>
      <div className="grid gap-6 lg:grid-cols-2">
        <div>
          <h4 className="mb-2 text-sm font-semibold text-body">Where the money goes (6 months)</h4>
          <Table headers={['Account', 'Total', '/mo', '% rev']}>
            {exp.map((e) => (
              <tr key={`${e.grp}:${e.account}`} className="hover:bg-surface-2">
                <td className="px-3 py-2">{e.account} <span className="text-xs text-muted">{e.grp === 'cogs' ? 'COGS' : ''}</span></td>
                <td className="px-3 py-2 font-semibold">{money(Number(e.total))}</td>
                <td className="px-3 py-2 text-muted">{money(Number(e.monthly_avg))}</td>
                <td className="px-3 py-2">{e.pct_of_revenue != null ? `${e.pct_of_revenue}%` : '—'}</td>
              </tr>
            ))}
          </Table>
        </div>
        {be.length > 0 && (
          <div>
            <h4 className="mb-2 text-sm font-semibold text-body">Break-even rate per mile (all costs ÷ all miles)</h4>
            <Table headers={['Month', 'Actual RPM', 'Break-even', 'Cushion']}>
              {be.map((b) => (
                <tr key={b.month} className="hover:bg-surface-2">
                  <td className="px-3 py-2">{b.month}</td>
                  <td className="px-3 py-2 font-semibold">${b.rpm_actual}</td>
                  <td className="px-3 py-2">${b.rpm_breakeven}</td>
                  <td className="px-3 py-2">
                    {b.cushion_pct != null && (
                      <span className={Number(b.cushion_pct) < 0 ? 'font-semibold text-red-600 dark:text-red-300' : Number(b.cushion_pct) < 10 ? 'text-amber-700 dark:text-amber-300' : 'text-green-600 dark:text-green-300'}>
                        {b.cushion_pct}%
                      </span>
                    )}
                  </td>
                </tr>
              ))}
            </Table>
          </div>
        )}
      </div>
    </div>
  )
}

// ── Reports ──────────────────────────────────────────────────────────────────
function ReportsTab() {
  const custQ = useQuery({ queryKey: ['acct-by-customer'], queryFn: () => acctRevenueByCustomer(365), retry: false })
  const marginQ = useQuery({ queryKey: ['acct-margin'], queryFn: () => acctMarginMonthly(12), retry: false })
  const margins = (marginQ.data ?? []).map((m) => ({ ...m, revenue: Number(m.revenue), margin: Number(m.margin) }))
  const custs = custQ.data ?? []
  return (
    <div className="space-y-6">
      <GlSection />
      {margins.length > 0 && (
        <div className="rounded-2xl border border-line bg-surface p-4">
          <h3 className="mb-2 text-sm font-semibold text-body">Revenue vs direct-cost margin (fuel + tolls + maintenance)</h3>
          <ResponsiveContainer width="100%" height={220}>
            <BarChart data={margins}>
              <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
              <XAxis dataKey="month" tick={{ fontSize: 11 }} />
              <YAxis tick={{ fontSize: 11 }} tickFormatter={(v: number) => `$${(v / 1000).toFixed(0)}k`} />
              <Tooltip formatter={(v) => money(Number(v))} />
              <Bar dataKey="revenue" name="Revenue" fill="#2563eb" radius={[4, 4, 0, 0]} />
              <Bar dataKey="margin" name="Margin" fill="#16a34a" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}
      <div>
        <h3 className="mb-2 text-sm font-semibold text-body">Revenue by customer — last 12 months</h3>
        {custQ.isLoading ? <p className="py-4 text-center text-muted">Loading…</p> : (
          <Table headers={['Customer', 'Billed', 'Share', 'Open', 'Past due', 'Avg days to pay', 'Inv.']}>
            {custs.slice(0, 30).map((c) => (
              <tr key={c.customer_id} className="hover:bg-surface-2">
                <td className="px-3 py-2.5 font-medium">{c.customer_name}</td>
                <td className="px-3 py-2.5 font-semibold">{money(Number(c.billed))}</td>
                <td className="px-3 py-2.5">
                  {c.share_pct != null ? (
                    <span className={Number(c.share_pct) > 30 ? 'font-semibold text-amber-700 dark:text-amber-300' : ''}>{c.share_pct}%</span>
                  ) : '—'}
                </td>
                <td className="px-3 py-2.5">{Number(c.open_balance) > 0 ? money(Number(c.open_balance)) : '—'}</td>
                <td className="px-3 py-2.5">{Number(c.past_due) > 0 ? <span className="text-red-600 dark:text-red-300">{money(Number(c.past_due))}</span> : '—'}</td>
                <td className="px-3 py-2.5">{c.avg_days_to_pay != null ? `${c.avg_days_to_pay}d` : '—'}</td>
                <td className="px-3 py-2.5 text-muted">{c.invoice_count}</td>
              </tr>
            ))}
          </Table>
        )}
        <p className="mt-1 text-xs text-muted">Share &gt;30% is concentration risk — one broker owns too much of your revenue.</p>
      </div>
    </div>
  )
}

// ── Record payment ───────────────────────────────────────────────────────────
function PaymentModal({ invoice, onClose }: { invoice: Invoice; onClose: () => void }) {
  const qc = useQueryClient()
  const [amount, setAmount] = useState('')
  const [method, setMethod] = useState('check')
  const [reference, setReference] = useState('')
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10))
  const [err, setErr] = useState('')
  const paymentsQ = useQuery({ queryKey: ['inv-payments', invoice.id], queryFn: () => listInvoicePayments(invoice.id) })
  const payments = paymentsQ.data ?? []
  const paidSoFar = payments.reduce((s, p) => s + Number(p.amount), 0)
  const remaining = Number(invoice.total) - paidSoFar

  const record = useMutation({
    mutationFn: () => recordInvoicePayment(invoice.id, Number(amount), method, reference || undefined, new Date(date).toISOString()),
    onSuccess: (res) => {
      qc.invalidateQueries({ queryKey: ['invoices'] })
      qc.invalidateQueries({ queryKey: ['acct-summary'] })
      qc.invalidateQueries({ queryKey: ['acct-aging'] })
      qc.invalidateQueries({ queryKey: ['inv-payments', invoice.id] })
      if (res.paid) onClose()
      else { setAmount(''); setReference('') }
    },
    onError: (e) => setErr(errorMessage(e)),
  })
  const del = useMutation({
    mutationFn: (id: number) => deleteInvoicePayment(id),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['invoices'] })
      qc.invalidateQueries({ queryKey: ['inv-payments', invoice.id] })
      qc.invalidateQueries({ queryKey: ['acct-summary'] })
    },
  })

  return (
    <Modal title={`Record payment — ${invoice.invoice_number}`} open onClose={onClose}>
      <div className="space-y-4">
        {err && <p className="rounded-lg bg-red-500/10 p-3 text-sm text-red-600 dark:text-red-300">{err}</p>}
        <p className="text-sm text-muted">
          {invoice.customer_name} · total {money(Number(invoice.total))}
          {paidSoFar > 0 && <> · paid {money(paidSoFar)} · <span className="font-semibold text-body">{money(remaining)} remaining</span></>}
        </p>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Amount">
            <input type="number" step="0.01" min="0" value={amount} onChange={(e) => setAmount(e.target.value)}
              placeholder={String(remaining)} className="w-full rounded-lg border border-line bg-surface px-3 py-2 text-sm" />
          </Field>
          <Field label="Method">
            <Select value={method} onChange={(e) => setMethod(e.target.value)}>
              <option value="check">Check</option>
              <option value="ach">ACH</option>
              <option value="wire">Wire</option>
              <option value="card">Card</option>
              <option value="factoring">Factoring</option>
              <option value="other">Other</option>
            </Select>
          </Field>
          <Field label="Reference (check # etc.)">
            <input value={reference} onChange={(e) => setReference(e.target.value)} className="w-full rounded-lg border border-line bg-surface px-3 py-2 text-sm" />
          </Field>
          <Field label="Received on">
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className="w-full rounded-lg border border-line bg-surface px-3 py-2 text-sm" />
          </Field>
        </div>
        {payments.length > 0 && (
          <div className="rounded-lg border border-line">
            {payments.map((p) => (
              <div key={p.id} className="flex items-center gap-3 border-b border-line px-3 py-2 text-sm last:border-0">
                <span className="font-medium">{money(Number(p.amount))}</span>
                <span className="text-muted">{p.method}{p.reference ? ` · ${p.reference}` : ''} · {formatDate(p.received_at)}</span>
                <button onClick={() => del.mutate(p.id)} className="ml-auto text-xs text-red-600 hover:underline">remove</button>
              </div>
            ))}
          </div>
        )}
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>Close</Button>
          <Button onClick={() => record.mutate()} disabled={!amount || Number(amount) <= 0 || record.isPending}>
            {record.isPending ? 'Recording…' : Number(amount) >= remaining ? 'Record — pays in full' : 'Record partial'}
          </Button>
        </div>
      </div>
    </Modal>
  )
}

// ── Email invoice ────────────────────────────────────────────────────────────
function EmailModal({ invoice, onClose }: { invoice: Invoice; onClose: () => void }) {
  const qc = useQueryClient()
  const customersQ = useQuery({ queryKey: ['customers', ''], queryFn: () => listCustomers() })
  const cust = (customersQ.data ?? []).find((c) => c.id === invoice.customer_id)
  const [to, setTo] = useState('')
  const [err, setErr] = useState('')
  const dest = to.trim() || cust?.email || ''

  const send = useMutation({
    mutationFn: async () => {
      const pdf = await invoicePdfBase64(invoice.id)
      return emailInvoice(invoice.id, pdf, to.trim() || undefined)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['invoices'] })
      onClose()
    },
    onError: (e) => setErr(errorMessage(e)),
  })

  return (
    <Modal title={`Email ${invoice.invoice_number}`} open onClose={onClose}>
      <div className="space-y-4">
        {err && <p className="rounded-lg bg-red-500/10 p-3 text-sm text-red-600 dark:text-red-300">{err}</p>}
        <p className="text-sm text-muted">
          Sends the invoice PDF ({money(Number(invoice.total))}) to <strong className="text-body">{invoice.customer_name}</strong> from the trux@ mailbox.
          {invoice.sent_at && <> Last sent {formatDate(invoice.sent_at)} to {invoice.sent_to}.</>}
        </p>
        <Field label={cust?.email ? `To (default: ${cust.email})` : 'To (no billing email on file — enter one)'}>
          <input
            value={to}
            onChange={(e) => setTo(e.target.value)}
            placeholder={cust?.email ?? 'billing@broker.com'}
            className="w-full rounded-lg border border-line bg-surface px-3 py-2 text-sm"
          />
        </Field>
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>Cancel</Button>
          <Button onClick={() => send.mutate()} disabled={!dest || send.isPending}>
            {send.isPending ? 'Sending…' : `Send to ${dest || '…'}`}
          </Button>
        </div>
      </div>
    </Modal>
  )
}

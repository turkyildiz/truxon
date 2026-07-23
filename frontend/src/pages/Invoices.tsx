/** Accounting — the money command center. Truxon as the complete billing
 * system: invoicing, emailing invoices to brokers, payment recording (checks/
 * ACH/factoring, partials), receivables with paid/unpaid/past-due toggles,
 * DSO, per-customer aging, unbilled-load leak detection, and revenue/margin
 * reports. QuickBooks stays an optional mirror (QBO-badged rows), not a
 * dependency. */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Fragment, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Area, AreaChart, Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { Badge, Button, Card, compareValues, Field, formatDate, LoadError, Modal, money, Select, type SortState, Table, toggleSort } from '../components/ui'
import {
  acctAging, acctMarginMonthly, acctRevenueByCustomer, acctRevenueMonthly, acctSummary, acctUnbilledLoads,
  addCollectionNote, approvedAccessorialsForLoads, cashflowForecast, collectionsQueue, loadsWithPod, type CollectionRow,
  factoringOverview, unmarkInvoiceFactored,
  createInvoice, decideAccessorial, deleteInvoicePayment, detentionEvents, emailInvoice, glBreakevenMonthly, glCfoSnapshot, glExpenseBreakdown,
  listAccessorials, proposeDetentionAccessorials,
  glPnlMonthly, listCustomers, listInvoicePayments, listInvoices, listLoads,
  creditMemoSummary, denimReconciliation, factoringCostSummary, paymentApplicationAudit, qboConnectUrl, qboStatus, qboWriteoffDecide, qboWriteoffList, recordInvoicePayment, revenueForecast, revRecDrift, setInvoiceStatus, slowPayRisk, triggerQboPull, voidInvoice,
} from '../data'
import { downloadCustomerStatement, downloadInvoicePdf, invoicePdfBase64 } from '../invoicePdf'
import { errorMessage } from '../supabase'
import type { Invoice } from '../types'

type Tab = 'overview' | 'receivables' | 'aging' | 'collections' | 'factoring' | 'unbilled' | 'detention' | 'forecast' | 'reports'
type Filter = 'all' | 'unpaid' | 'pastdue' | 'paid' | 'draft' | 'void'

const TABS: { key: Tab; label: string }[] = [
  { key: 'overview', label: 'Overview' },
  { key: 'receivables', label: 'Receivables' },
  { key: 'aging', label: 'Aging' },
  { key: 'collections', label: '📞 Collections' },
  { key: 'factoring', label: '🏦 Factoring' },
  { key: 'unbilled', label: 'Unbilled' },
  { key: 'detention', label: '⏱️ Detention' },
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

/** Factored invoice whose only remaining "balance" is the factor's fee sliver
 * left open on the books — Denim paid net; the customer owes nothing. Not
 * receivable, not past due; the sliver clears when the fee is written off in
 * QuickBooks. Threshold: ≤15% of total and ≤$500 (real fees run 2-6%). */
const isFeeResidual = (inv: Invoice) =>
  inv.status === 'sent' && !!inv.factored_at && inv.source === 'qbo' &&
  inv.qbo_balance != null && inv.qbo_balance > 0 &&
  inv.qbo_balance <= Math.min(0.15 * inv.total, 500)

const isPastDue = (inv: Invoice) =>
  inv.status === 'sent' && !!inv.due_date && new Date(inv.due_date) < new Date() && !isFeeResidual(inv)
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
  const [params] = useSearchParams()
  const initialTab = (['overview', 'receivables', 'aging', 'collections', 'unbilled', 'detention', 'forecast', 'reports'] as Tab[])
    .find((t) => t === params.get('tab')) ?? 'overview'
  const [tab, setTab] = useState<Tab>(initialTab)
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
  // Approved accessorials (detention etc.) that create_invoice will fold into the
  // total — fetched for every billable load so the preview can add the ones on
  // selected loads and match the server to the penny (M-1).
  const { data: approvedAcc = [] } = useQuery({
    queryKey: ['accessorials', 'approved', billableLoads.map((l) => l.id).sort().join(',')],
    queryFn: () => approvedAccessorialsForLoads(billableLoads.map((l) => l.id)),
    enabled: creating && billableLoads.length > 0,
  })
  // Which billable loads have a POD/delivery-evidence doc on file — bill without
  // one and the broker often short-pays or disputes (POD-before-billing).
  const { data: podLoadIds = [] } = useQuery({
    queryKey: ['loads', 'with-pod', billableLoads.map((l) => l.id).sort().join(',')],
    queryFn: () => loadsWithPod(billableLoads.map((l) => l.id)),
    enabled: creating && billableLoads.length > 0,
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

  // Click-to-sort on the list columns (default: newest first).
  const [sort, setSort] = useState<SortState>({ key: 'invoice_date', dir: 'desc' })
  const sorted = useMemo(() => {
    const val = (inv: Invoice): unknown => {
      switch (sort.key) {
        case 'number': return inv.source === 'qbo' ? inv.qbo_doc_number : inv.invoice_number
        case 'customer': return inv.customer_name
        case 'invoice_date': return inv.invoice_date ? new Date(inv.invoice_date).getTime() : null
        case 'due_date': return inv.due_date ? new Date(inv.due_date).getTime() : null
        case 'total': return Number(inv.total)
        case 'status': return inv.status
        default: return null
      }
    }
    const dir = sort.dir === 'asc' ? 1 : -1
    // blanks/nulls stay last in BOTH directions (reversing would surface them)
    return [...filtered].sort((a, b) => {
      const av = val(a), bv = val(b)
      const aNil = av == null || av === ''
      const bNil = bv == null || bv === ''
      if (aNil && bNil) return 0
      if (aNil) return 1
      if (bNil) return -1
      return dir * compareValues(av, bv)
    })
  }, [filtered, sort])

  const filteredTotal = filtered.reduce((s, i) => s + Number(i.total), 0)
  const filterCount = (f: Filter) =>
    invoices.filter((inv) =>
      f === 'all' ? true
      : f === 'unpaid' ? inv.status === 'sent'
      : f === 'pastdue' ? isPastDue(inv)
      : inv.status === f).length

  const podSet = new Set(podLoadIds)
  const missingPodSelected = billableLoads.filter((l) => selected.has(l.id) && !podSet.has(l.id))
  const loadsSubtotal = billableLoads.filter((l) => selected.has(l.id)).reduce((sum, l) => sum + Number(l.rate), 0)
  const selectedAcc = approvedAcc.filter((a) => selected.has(a.load_id))
  const accSubtotal = selectedAcc.reduce((sum, a) => sum + Number(a.amount), 0)
  const total = loadsSubtotal + accSubtotal
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
              <Table
                headers={[
                  { label: 'Invoice #', key: 'number' },
                  { label: 'Customer', key: 'customer' },
                  { label: 'Date', key: 'invoice_date' },
                  { label: 'Due', key: 'due_date' },
                  { label: 'Total', key: 'total' },
                  { label: 'Status', key: 'status' },
                  '',
                ]}
                sort={sort}
                onSort={(k) => setSort((p) => toggleSort(p, k))}
              >
                {sorted.map((inv) => (
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
                      {isFeeResidual(inv) && (
                        <span
                          className="ml-1.5 rounded bg-teal-500/15 px-1.5 py-0.5 text-xs font-semibold text-teal-600 dark:text-teal-300"
                          title={`Paid by ${inv.factor_name ?? 'factor'} net of fee — the open ${money(inv.qbo_balance!)} is the factoring fee awaiting write-off in QuickBooks, not customer debt`}
                        >
                          settled · fee {money(inv.qbo_balance!)}
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
      {tab === 'collections' && <CollectionsTab />}
      {tab === 'factoring' && <FactoringTab />}
      {tab === 'unbilled' && <UnbilledTab onBill={billCustomer} />}
      {tab === 'detention' && <DetentionTab />}
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
                    {!podSet.has(l.id) && (
                      <span className="rounded bg-amber-500/15 px-1.5 py-0.5 text-[11px] font-medium text-amber-700 dark:text-amber-300" title="No proof-of-delivery document on file">⚠️ No POD</span>
                    )}
                    <span className="flex-1 truncate text-muted">{l.delivery_address}</span>
                    <span className="font-semibold">{money(Number(l.rate))}</span>
                  </label>
                ))}
              </div>
            )
          )}
          {missingPodSelected.length > 0 && (
            <div className="rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm text-amber-800 dark:text-amber-200">
              ⚠️ {missingPodSelected.length} selected {missingPodSelected.length === 1 ? 'load has' : 'loads have'} no POD on file
              ({missingPodSelected.map((l) => l.load_number).join(', ')}). Brokers often short-pay or dispute invoices
              billed without proof of delivery — you can still bill, but attach the POD first when you can.
            </div>
          )}
          {selected.size > 0 && (
            <div className="space-y-1 text-right text-sm">
              <div className="text-muted">{selected.size} {selected.size === 1 ? 'load' : 'loads'} · {money(loadsSubtotal)}</div>
              {selectedAcc.length > 0 && (
                <>
                  {selectedAcc.map((a) => (
                    <div key={a.id} className="text-muted">
                      + {a.atype === 'detention' ? 'Detention' : a.atype} · {money(Number(a.amount))}
                    </div>
                  ))}
                  <div className="text-xs text-muted">{selectedAcc.length} approved {selectedAcc.length === 1 ? 'accessorial' : 'accessorials'} ride this invoice</div>
                </>
              )}
              <div>Total · <span className="font-bold">{money(total)}</span></div>
            </div>
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
          Money <strong>in</strong> is factoring-aware: the <strong>advance</strong> (your observed rate) lands days after invoicing — including future hauling at your trailing 8-week revenue run-rate — while <strong>reserves</strong> land at each broker's learned pay behavior. Money <strong>out</strong> is your trailing 8-week average of tracked costs (fuel + driver pay + truck fixed + tolls + maintenance). A transparent estimate, not a guarantee.
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
          <Table headers={['Invoice', 'Customer', 'Open', 'Pays ~', 'Days late', 'Risk']}>
            {risky.map((r) => (
              <tr key={r.invoice_id} className="border-b border-line">
                <td className="px-3 py-2 font-medium text-brand">{r.invoice_number}</td>
                <td className="px-3 py-2">{r.customer}</td>
                <td className="px-3 py-2">{money(Number(r.outstanding))}</td>
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

/** Fee-sliver write-off proposals. Approving changes status only — the books
 * are applied by the accountant in QBO; the 30-min mirror clears them here. */
function WriteoffCard() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['qbo-writeoffs'], queryFn: qboWriteoffList, retry: false })
  const decide = useMutation({
    mutationFn: ({ id, approve }: { id: number; approve: boolean }) => qboWriteoffDecide(id, approve),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['qbo-writeoffs'] }),
  })
  const d = q.data
  if (q.isError || !d || d.rows.length === 0) return null
  const proposed = d.rows.filter((r) => r.status === 'proposed')
  const approved = d.rows.filter((r) => r.status === 'approved')
  return (
    <Card title={`🧾 Factoring-fee write-offs — ${money(d.proposed_total)} proposed`}>
      <p className="mb-2 text-xs text-muted">
        These invoices are settled; only the factoring fee is left on the books as a fake receivable.
        Approving here <strong>does not touch QBO</strong> — it builds the packet below for your accountant
        to apply (write-off or credit memo). Once applied in QBO, the mirror clears them automatically.
      </p>
      {proposed.length > 0 && (
        <div className="max-h-64 overflow-y-auto">
          <table className="w-full text-sm">
            <tbody>
              {proposed.map((r) => (
                <tr key={r.id} className="border-t border-line">
                  <td className="px-2 py-1.5 font-medium">{r.invoice_number}</td>
                  <td className="px-2 py-1.5 text-muted">{r.customer ?? '—'}</td>
                  <td className="px-2 py-1.5">{formatDate(r.invoice_date)}</td>
                  <td className="px-2 py-1.5 font-semibold">{money(Number(r.amount))}</td>
                  <td className="px-2 py-1.5 text-right">
                    <button type="button" className="btn btn-primary mr-1 px-2 py-0.5 text-xs" disabled={decide.isPending}
                      onClick={() => decide.mutate({ id: r.id, approve: true })}>Approve</button>
                    <button type="button" className="btn px-2 py-0.5 text-xs" disabled={decide.isPending}
                      onClick={() => decide.mutate({ id: r.id, approve: false })}>Dismiss</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {approved.length > 0 && (
        <div className="mt-3">
          <div className="text-xs font-semibold uppercase tracking-wide text-muted">
            Accountant packet — approved, awaiting QBO entry ({money(d.approved_total)})
          </div>
          <p className="text-sm text-muted">
            {approved.map((r) => `${r.invoice_number} ${money(Number(r.amount))}`).join(' · ')}
          </p>
        </div>
      )}
    </Card>
  )
}

/** What factoring costs (true fees ÷ face) and what it buys (days of float). */
function FactoringCostCard() {
  const q = useQuery({ queryKey: ['factoring-cost'], queryFn: factoringCostSummary, retry: false })
  const d = q.data
  if (q.isError || !d || d.fees_total === 0) return null
  const recent = d.months.slice(-6)
  return (
    <Card title="💸 Cost of factoring">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Kpi label="Effective rate" value={d.effective_rate_pct != null ? `${d.effective_rate_pct}%` : '—'} sub={`${money(d.fees_total)} on ${money(d.face_total)}`} />
        <Kpi label="Book pay speed" value={d.book_days_to_pay != null ? `${d.book_days_to_pay}d` : '—'} sub="brokers, on the books" />
        <Kpi label="Float gained" value={`~${d.days_of_float_gained}d`} sub="advance in ~2 days instead" tone="good" />
        <Kpi label="Annualized cost" value={d.annualized_cost_pct != null ? `${d.annualized_cost_pct}%` : '—'} sub="compare to any other money" tone={d.annualized_cost_pct != null && d.annualized_cost_pct > 25 ? 'warn' : undefined} />
      </div>
      {recent.length > 0 && (
        <table className="mt-3 w-full text-sm">
          <thead><tr className="text-left text-xs uppercase tracking-wide text-muted">
            <th className="px-2 py-1">Month</th><th className="px-2 py-1">Invoices</th>
            <th className="px-2 py-1">Face</th><th className="px-2 py-1">Fees</th><th className="px-2 py-1">Rate</th>
          </tr></thead>
          <tbody>
            {recent.map((m) => (
              <tr key={m.month} className="border-t border-line">
                <td className="px-2 py-1 font-medium">{m.month}</td>
                <td className="px-2 py-1">{m.invoices}</td>
                <td className="px-2 py-1">{money(m.face)}</td>
                <td className="px-2 py-1">{money(m.fees)}</td>
                <td className="px-2 py-1">{m.rate_pct != null ? `${m.rate_pct}%` : '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Card>
  )
}

/** Denim's statement vs our books — agreement or the exact disagreements. */
function DenimReconCard() {
  const q = useQuery({ queryKey: ['denim-recon'], queryFn: denimReconciliation, retry: false })
  const d = q.data
  if (q.isError || !d || d.jobs_seen === 0) return null
  const clean = d.fee_mismatches.length === 0 && d.unmatched_jobs.length === 0
  return (
    <Card title="🔎 Denim ↔ books reconciliation">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Kpi label="Denim jobs" value={String(d.jobs_seen)} sub={`${d.jobs_matched} matched to invoices`} />
        <Kpi label="Denim fees" value={money(d.denim_fees_total)} sub="per their statement" />
        <Kpi label="Captured fees" value={money(d.captured_fees_total)} sub="on our books" tone={Math.abs(d.denim_fees_total - d.captured_fees_total) < 1 ? 'good' : 'warn'} />
        <Kpi label="Factored, no Denim job" value={String(d.factored_without_job)} sub="pre-Denim history or other factor" />
      </div>
      {clean ? (
        <p className="mt-2 text-sm text-green-700 dark:text-green-300">Every Denim job matches an invoice and every fee agrees ✓</p>
      ) : (
        <div className="mt-2 space-y-1 text-sm">
          {d.fee_mismatches.map((m) => (
            <p key={m.invoice} className="text-amber-700 dark:text-amber-300">
              {m.invoice}: Denim says {money(m.denim_fee)}, books say {m.captured_fee != null ? money(m.captured_fee) : '—'}
            </p>
          ))}
          {d.unmatched_jobs.length > 0 && (
            <p className="text-muted">
              {d.unmatched_jobs.length} Denim job{d.unmatched_jobs.length > 1 ? 's' : ''} with no matching invoice:{' '}
              {d.unmatched_jobs.slice(0, 6).map((u) => u.ref ?? u.job).join(', ')}{d.unmatched_jobs.length > 6 ? '…' : ''}
            </p>
          )}
        </div>
      )}
    </Card>
  )
}

function FactoringTab() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['factoring'], queryFn: factoringOverview, retry: false })
  const unfactor = useMutation({
    mutationFn: (id: number) => unmarkInvoiceFactored(id),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['factoring'] }); qc.invalidateQueries({ queryKey: ['acct-summary'] }) },
  })

  const [sort, setSort] = useState<SortState>({ key: 'reserve_pending', dir: 'desc' })

  if (q.isLoading) return <p className="py-8 text-center text-muted">Loading…</p>
  if (q.isError) return <LoadError error={q.error} onRetry={() => q.refetch()} />
  const s = q.data!.summary
  const dir = sort.dir === 'asc' ? 1 : -1
  const rows = [...q.data!.invoices].sort((a, b) => {
    const pick = (r: typeof a): unknown => {
      switch (sort.key) {
        case 'number': return r.invoice_number
        case 'customer': return r.customer
        case 'total': return Number(r.total)
        case 'advanced': return Number(r.advanced)
        case 'reserve_pending': return Number(r.reserve_pending)
        case 'factored_at': return r.factored_at ? new Date(r.factored_at).getTime() : null
        case 'status': return r.reserve_released
        default: return null
      }
    }
    const av = pick(a), bv = pick(b)
    if (av == null && bv == null) return 0
    if (av == null) return 1
    if (bv == null) return -1
    return dir * compareValues(av, bv)
  })

  return (
    <div className="space-y-4">
      <WriteoffCard />
      <FactoringCostCard />
      <DenimReconCard />
      <p className="text-sm text-muted">
        Factored invoices are financed by <strong>{rows[0]?.factor ?? 'your factor'}</strong>: you get the
        advance up front and the <strong>reserve</strong> later, when the broker pays the factor. These are
        <strong> not overdue from the broker</strong> — the factor owns collecting them — so they're pulled out of
        Receivables/Aging and tracked here instead. Fees fill in once the Denim API sync is connected.
      </p>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Kpi label="Factored (open)" value={money(s.total_factored)} sub={`${s.factored_count} invoices`} />
        <Kpi label="Advanced" value={money(s.advanced)} sub="received up front" tone="good" />
        <Kpi label="Reserve pending" value={money(s.reserve_pending)} sub="owed by the factor" tone="warn" />
        <Kpi label="Factoring fees" value={s.fees > 0 ? money(s.fees) : '—'} sub={s.fees > 0 ? 'this period' : 'TBD (agreement)'} />
      </div>

      {rows.length === 0 ? (
        <p className="py-8 text-center text-muted">No factored invoices. Mark an invoice factored from Receivables.</p>
      ) : (
        <Table
          headers={[
            { label: 'Invoice', key: 'number' },
            { label: 'Broker', key: 'customer' },
            { label: 'Total', key: 'total' },
            { label: 'Advanced', key: 'advanced' },
            { label: 'Reserve pending', key: 'reserve_pending' },
            { label: 'Factored', key: 'factored_at' },
            { label: 'Status', key: 'status' },
            '',
          ]}
          sort={sort}
          onSort={(k) => setSort((p) => toggleSort(p, k))}
        >
          {rows.map((r) => (
            <tr key={r.id} className="hover:bg-surface-2">
              <td className="px-3 py-2.5 font-medium">{r.invoice_number}</td>
              <td className="px-3 py-2.5 text-muted">{r.customer ?? '—'}</td>
              <td className="px-3 py-2.5">{money(Number(r.total))}</td>
              <td className="px-3 py-2.5 text-green-700 dark:text-green-300">{money(Number(r.advanced))}</td>
              <td className="px-3 py-2.5 font-semibold text-amber-700 dark:text-amber-300">{money(Number(r.reserve_pending))}</td>
              <td className="px-3 py-2.5 text-muted">{r.factored_at ? formatDate(r.factored_at) : '—'}</td>
              <td className="px-3 py-2.5">
                {r.reserve_released
                  ? <span className="rounded px-1.5 py-0.5 text-xs font-semibold bg-green-500/15 text-green-700 dark:text-green-300">Reserve released</span>
                  : <span className="rounded px-1.5 py-0.5 text-xs font-semibold bg-amber-500/15 text-amber-700 dark:text-amber-300">Reserve pending</span>}
              </td>
              <td className="px-3 py-2.5 text-right">
                <button
                  onClick={() => unfactor.mutate(r.id)}
                  disabled={unfactor.isPending}
                  className="rounded-lg border border-line px-2 py-1 text-xs text-muted hover:text-body disabled:opacity-50"
                  title="Not actually factored? Put it back into broker A/R."
                >
                  Un-factor
                </button>
              </td>
            </tr>
          ))}
        </Table>
      )}
    </div>
  )
}

function CollectionsTab() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['collections-queue'], queryFn: collectionsQueue, retry: false })
  const [open, setOpen] = useState<number | null>(null)
  const [noteFor, setNoteFor] = useState<CollectionRow | null>(null)
  const [note, setNote] = useState('')
  const [promiseAmt, setPromiseAmt] = useState('')
  const [promiseDate, setPromiseDate] = useState('')

  const saveNote = useMutation({
    mutationFn: () => addCollectionNote({
      customer_id: noteFor!.customer_id,
      note,
      promised_amount: promiseAmt ? Number(promiseAmt) : null,
      promised_date: promiseDate || null,
    }),
    onSuccess: () => {
      setNoteFor(null); setNote(''); setPromiseAmt(''); setPromiseDate('')
      qc.invalidateQueries({ queryKey: ['collections-queue'] })
    },
  })

  if (q.isLoading) return <p className="py-8 text-center text-muted">Loading…</p>
  if (q.isError) return <LoadError error={q.error} onRetry={() => q.refetch()} />
  const rows = q.data ?? []
  if (rows.length === 0) return <p className="py-8 text-center text-muted">Nothing overdue. 🎉</p>
  const total = rows.reduce((s, r) => s + Number(r.overdue_total), 0)

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted">
        {money(total)} overdue across {rows.length} customer{rows.length === 1 ? '' : 's'}, ranked by
        dollars × age. Forest drafts a payment reminder for review every Monday — nothing sends without you.
      </p>
      <Table headers={['Customer', 'Contact', 'Overdue', 'Inv.', 'Oldest', 'Usually pays in', 'Promise', '']}>
        {rows.map((r) => (
          <Fragment key={r.customer_id}>
            <tr className="cursor-pointer hover:bg-surface-2" onClick={() => setOpen(open === r.customer_id ? null : r.customer_id)}>
              <td className="px-3 py-2.5 font-medium">{r.company_name}</td>
              <td className="px-3 py-2.5 text-muted">
                {r.contact_person || '—'}
                {r.phone && <span className="block text-xs">{r.phone}</span>}
                {r.email && <span className="block text-xs">{r.email}</span>}
              </td>
              <td className="px-3 py-2.5 font-semibold text-red-600 dark:text-red-300">{money(Number(r.overdue_total))}</td>
              <td className="px-3 py-2.5 text-muted">{r.overdue_count}</td>
              <td className="px-3 py-2.5">
                <span className={r.oldest_days >= 30 ? 'font-semibold text-red-600 dark:text-red-300' : 'text-amber-700 dark:text-amber-300'}>
                  {r.oldest_days}d
                </span>
              </td>
              <td className="px-3 py-2.5 text-muted">{r.avg_days_to_pay != null ? `${r.avg_days_to_pay}d` : '—'}</td>
              <td className="px-3 py-2.5 text-sm">
                {r.last_promise ? (
                  <span title={r.last_promise.note}>
                    {r.last_promise.promised_amount != null && money(Number(r.last_promise.promised_amount))}
                    {r.last_promise.promised_date && ` by ${formatDate(r.last_promise.promised_date)}`}
                    {r.last_promise.promised_amount == null && !r.last_promise.promised_date && '📝'}
                  </span>
                ) : '—'}
              </td>
              <td className="px-3 py-2.5">
                <Button variant="secondary" onClick={(e) => { e.stopPropagation(); setNoteFor(r) }}>+ Note</Button>
                {r.email && (
                  <a
                    className="btn ml-1 px-2 py-0.5 text-xs"
                    title="Open a pre-written statement email in your mail client — nothing sends until you hit send. Grab the statement PDF from the Aging tab to attach."
                    onClick={(e) => e.stopPropagation()}
                    href={`mailto:${r.email}?subject=${encodeURIComponent(`Statement of account — ${money(Number(r.overdue_total))} past due`)}&body=${encodeURIComponent(
                      `Hi${r.contact_person ? ` ${r.contact_person}` : ''},\n\nOur records show ${money(Number(r.overdue_total))} past due across ${r.overdue_count} invoice${Number(r.overdue_count) === 1 ? '' : 's'}, the oldest now ${r.oldest_days} days. A detailed statement is attached.\n\nCould you let us know when we can expect payment?\n\nThank you`,
                    )}`}
                  >✉️ Draft</a>
                )}
                <button
                  type="button" className="btn ml-1 px-2 py-0.5 text-xs" title="Download statement PDF to attach"
                  onClick={(e) => { e.stopPropagation(); void downloadCustomerStatement(r.customer_id) }}
                >PDF</button>
              </td>
            </tr>
            {open === r.customer_id && (
              <tr>
                <td colSpan={8} className="bg-surface-2 px-6 py-3">
                  <ul className="space-y-1 text-sm">
                    {r.invoices.map((inv) => (
                      <li key={inv.invoice_id} className="flex gap-4">
                        <span className="font-medium">{inv.invoice_number}</span>
                        <span>{money(Number(inv.balance))}</span>
                        <span className="text-muted">due {formatDate(inv.due_date)}</span>
                        <span className="text-red-600 dark:text-red-300">{inv.days_late} days late</span>
                      </li>
                    ))}
                  </ul>
                </td>
              </tr>
            )}
          </Fragment>
        ))}
      </Table>

      {noteFor && (
        <Modal title={`Call note — ${noteFor.company_name}`} open onClose={() => setNoteFor(null)}>
          <div className="space-y-3">
            <Field label="What happened">
              <textarea
                className="w-full rounded-lg border border-edge bg-surface px-3 py-2 text-sm"
                rows={3} value={note} onChange={(e) => setNote(e.target.value)}
                placeholder="Spoke with AP — check going out Friday…"
              />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Promised amount (optional)">
                <input type="number" className="w-full rounded-lg border border-edge bg-surface px-3 py-2 text-sm"
                  value={promiseAmt} onChange={(e) => setPromiseAmt(e.target.value)} />
              </Field>
              <Field label="Promised date (optional)">
                <input type="date" className="w-full rounded-lg border border-edge bg-surface px-3 py-2 text-sm"
                  value={promiseDate} onChange={(e) => setPromiseDate(e.target.value)} />
              </Field>
            </div>
            {saveNote.isError && <p className="text-sm text-red-600">{errorMessage(saveNote.error)}</p>}
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setNoteFor(null)}>Cancel</Button>
              <Button onClick={() => saveNote.mutate()} disabled={!note.trim() || saveNote.isPending}>
                {saveNote.isPending ? 'Saving…' : 'Save note'}
              </Button>
            </div>
          </div>
        </Modal>
      )}
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
    <Table headers={['Customer', 'Current', '1–30', '31–60', '61–90', '90+', 'Total', 'Inv.', '']}>
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
          <td className="px-3 py-2.5">
            <button type="button" className="btn px-2 py-0.5 text-xs" title="Download statement PDF"
              onClick={() => void downloadCustomerStatement(r.customer_id)}>Statement</button>
          </td>
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

// ── Detention (Northstar: ELD dwell vs free time) ────────────────────────────
function DetentionTab() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['detention'], queryFn: () => detentionEvents(45), retry: false })
  const accQ = useQuery({ queryKey: ['accessorials'], queryFn: listAccessorials, retry: false })
  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['accessorials'] })
    qc.invalidateQueries({ queryKey: ['detention'] })
  }
  const decide = useMutation({
    mutationFn: ({ id, approve }: { id: number; approve: boolean }) => decideAccessorial(id, approve),
    onSuccess: refresh,
  })
  const rescan = useMutation({ mutationFn: proposeDetentionAccessorials, onSuccess: refresh })
  if (q.isLoading) return <p className="py-8 text-center text-muted">Measuring dwell from ELD breadcrumbs…</p>
  if (q.isError) return <LoadError error={q.error} onRetry={() => q.refetch()} />
  const rows = q.data ?? []
  const accByKey = new Map(
    (accQ.data ?? []).filter((a) => a.atype === 'detention')
      .map((a) => [`${a.load_id}:${a.stop_type}`, a]),
  )
  const total = rows.reduce((s, r) => s + Number(r.est_pay), 0)
  const hrs = (m: number) => `${Math.floor(m / 60)}h ${m % 60}m`
  return (
    <>
      <p className="mb-3 rounded-lg bg-amber-500/10 p-3 text-sm text-amber-800 dark:text-amber-200">
        {rows.length === 0
          ? 'No detention detected in the last 45 days (needs ELD coverage over the stop window). As breadcrumb history grows, held-up loads will surface here.'
          : <>⏱️ <strong>{money(total)}</strong> in billable detention across {rows.length} stop{rows.length === 1 ? '' : 's'} (last 45 days) — measured from actual GPS dwell past 2h free time. Bill it back before the broker forgets.</>}
      </p>
      {rows.length > 0 && (
        <Table headers={['Load #', 'Customer', 'Stop', 'State', 'Arrived', 'Left', 'Dwell', 'Over free', 'Est. owed', 'Bill']}>
          {rows.map((r) => {
            const acc = accByKey.get(`${r.load_id}:${r.stop_type}`)
            return (
              <tr key={`${r.load_id}:${r.stop_type}`} className="hover:bg-surface-2">
                <td className="px-3 py-2.5 font-medium text-brand">{r.load_number}</td>
                <td className="px-3 py-2.5">{r.customer}</td>
                <td className="px-3 py-2.5 capitalize">{r.stop_type}</td>
                <td className="px-3 py-2.5 text-muted">{r.stop_state ?? '—'}</td>
                <td className="px-3 py-2.5 text-muted">{formatDate(r.arrival)}</td>
                <td className="px-3 py-2.5 text-muted">{formatDate(r.departure)}</td>
                <td className="px-3 py-2.5">{hrs(r.dwell_min)}</td>
                <td className="px-3 py-2.5 font-semibold text-amber-700 dark:text-amber-300">{hrs(r.detention_min)}</td>
                <td className="px-3 py-2.5 font-semibold">{money(Number(r.est_pay))}</td>
                <td className="px-3 py-2.5">
                  {!acc ? (
                    <button className="text-xs text-muted hover:underline" disabled={rescan.isPending}
                      onClick={() => rescan.mutate()}>
                      {rescan.isPending ? 'Scanning…' : 'Re-scan'}
                    </button>
                  ) : acc.status === 'proposed' ? (
                    <span className="flex gap-1.5">
                      <button
                        className="rounded-lg bg-emerald-600 px-2 py-1 text-xs font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
                        disabled={decide.isPending}
                        onClick={() => decide.mutate({ id: acc.id, approve: true })}>
                        ✓ Bill it
                      </button>
                      <button
                        className="rounded-lg border border-line px-2 py-1 text-xs text-muted hover:text-body disabled:opacity-50"
                        disabled={decide.isPending}
                        onClick={() => decide.mutate({ id: acc.id, approve: false })}>
                        Skip
                      </button>
                    </span>
                  ) : (
                    <Badge status={acc.status} />
                  )}
                </td>
              </tr>
            )
          })}
        </Table>
      )}
      {rows.length > 0 && (
        <p className="mt-2 text-xs text-muted">
          Estimate at $50/hr after 2h free time; confirm the broker's rate-con terms before approving.
          Approved detention is added automatically to the load's invoice when it is billed.
        </p>
      )}
      {(accQ.data ?? []).some((a) => a.atype === 'detention' && a.evidence) && (
        <div className="mt-6">
          <h3 className="mb-2 text-sm font-semibold">📎 Evidence on file</h3>
          <p className="mb-2 text-xs text-muted">
            ELD proof is banked on each charge the moment it's proposed — it outlives the 2-day GPS
            retention, so a broker dispute months later still has its exhibit.
          </p>
          <Table headers={['Load', 'Stop', 'Arrived', 'Left', 'Dwell', 'Billable', 'Amount', 'Status']}>
            {(accQ.data ?? [])
              .filter((a) => a.atype === 'detention' && a.evidence)
              .map((a) => (
                <tr key={a.id} className="hover:bg-surface-2">
                  <td className="px-3 py-2.5 text-muted">#{a.load_id}</td>
                  <td className="px-3 py-2.5 capitalize">{a.stop_type}</td>
                  <td className="px-3 py-2.5 text-muted">{formatDate(a.evidence!.arrival)}</td>
                  <td className="px-3 py-2.5 text-muted">{formatDate(a.evidence!.departure)}</td>
                  <td className="px-3 py-2.5">{hrs(a.evidence!.dwell_min)}</td>
                  <td className="px-3 py-2.5 font-semibold text-amber-700 dark:text-amber-300">{hrs(a.evidence!.detention_min)}</td>
                  <td className="px-3 py-2.5 font-semibold">{money(Number(a.amount))}</td>
                  <td className="px-3 py-2.5"><Badge status={a.status} /></td>
                </tr>
              ))}
          </Table>
        </div>
      )}
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
/** Payments that landed wrong — the mismatch lists an auditor would build. */
function PaymentAuditCard() {
  const q = useQuery({ queryKey: ['payment-audit'], queryFn: paymentApplicationAudit, retry: false })
  const d = q.data
  if (q.isError || !d) return null
  const total = d.paid_but_open_in_qbo.length + d.settled_in_qbo_but_open.length + d.overpaid.length
  if (total === 0) {
    return (
      <div className="rounded-2xl border border-line bg-surface p-4">
        <h3 className="text-sm font-semibold text-body">Payment application audit</h3>
        <p className="mt-1 text-sm text-green-700 dark:text-green-300">Every payment agrees with the books ✓</p>
      </div>
    )
  }
  const section = (title: string, rows: { invoice: string; customer: string | null }[], extra: (r: never) => string) => rows.length > 0 && (
    <div className="mt-2">
      <div className="text-xs font-semibold uppercase tracking-wide text-amber-700 dark:text-amber-300">{title} ({rows.length})</div>
      <ul className="text-sm">
        {rows.slice(0, 8).map((r) => (
          <li key={r.invoice} className="text-muted">
            <span className="font-medium text-body">{r.invoice}</span> {r.customer ?? ''} — {extra(r as never)}
          </li>
        ))}
      </ul>
    </div>
  )
  return (
    <div className="rounded-2xl border border-line bg-surface p-4">
      <h3 className="text-sm font-semibold text-body">Payment application audit — {total} mismatch{total === 1 ? '' : 'es'}</h3>
      {section('Marked paid here, still open in QBO', d.paid_but_open_in_qbo,
        (r: { qbo_balance: number }) => `QBO balance ${money(Number(r.qbo_balance))}`)}
      {section('Collected in QBO, still open here', d.settled_in_qbo_but_open,
        (r: { days_open: number }) => `mark it paid — open ${r.days_open}d`)}
      {section('Payments exceed invoice total', d.overpaid,
        (r: { total: number; payments: number }) => `${money(Number(r.payments))} on a ${money(Number(r.total))} invoice`)}
    </div>
  )
}

/** Credit memos = revenue walked back. The invoice-accuracy scoreboard. */
function CreditMemoCard() {
  const q = useQuery({ queryKey: ['credit-memos'], queryFn: () => creditMemoSummary(12), retry: false })
  const d = q.data
  if (q.isError || !d) return null
  return (
    <div className="rounded-2xl border border-line bg-surface p-4">
      <h3 className="mb-2 text-sm font-semibold text-body">Credit memos — invoice accuracy, last 12 months</h3>
      <div className="grid grid-cols-3 gap-3">
        <Kpi label="Credit memos" value={String(d.credit_memos)} sub={money(d.credit_memo_total)} />
        <Kpi label="Credit-memo rate" value={d.credit_memo_rate_pct != null ? `${d.credit_memo_rate_pct}%` : '—'} sub="of invoiced revenue" tone={Number(d.credit_memo_rate_pct) > 1 ? 'warn' : undefined} />
        <Kpi label="Invoice accuracy" value={`${d.invoice_accuracy_pct}%`} sub="playbook #73" tone={d.invoice_accuracy_pct >= 99 ? 'good' : 'warn'} />
      </div>
      {d.recent.length > 0 ? (
        <table className="mt-3 w-full text-sm">
          <tbody>
            {d.recent.slice(0, 5).map((r) => (
              <tr key={r.doc} className="border-t border-line">
                <td className="px-2 py-1 font-medium">{r.doc}</td>
                <td className="px-2 py-1 text-muted">{r.customer ?? '—'}</td>
                <td className="px-2 py-1">{formatDate(r.date)}</td>
                <td className="px-2 py-1">{money(Number(r.total))}</td>
                <td className="px-2 py-1 text-muted">{r.memo ?? ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <p className="mt-2 text-sm text-green-700 dark:text-green-300">No credit memos in QBO for this period ✓</p>
      )}
    </div>
  )
}

/** Earned (delivery month) vs booked (invoice month) — the cross-month drift. */
function RevRecCard() {
  const q = useQuery({ queryKey: ['rev-rec-drift'], queryFn: () => revRecDrift(6), retry: false })
  const rows = q.data ?? []
  if (q.isError || rows.length === 0) return null
  const anyDrift = rows.some((m) => m.cross_month_loads > 0)
  return (
    <div className="rounded-2xl border border-line bg-surface p-4">
      <h3 className="mb-1 text-sm font-semibold text-body">Revenue recognition — earned vs booked</h3>
      <p className="mb-2 text-xs text-muted">
        Earned = loads by delivery month; booked = invoices by invoice month. Cross-month = freight
        billed in a different month than it delivered — why a &ldquo;great month&rdquo; can be last month&rsquo;s work.
        A persistent gap with no cross-month loads means invoices not linked to Truxon loads (QBO history,
        accessorial-only billing) — a linkage gap, not a timing problem.
      </p>
      <Table headers={['Month', 'Earned', 'Booked', 'Gap', 'Cross-month']}>
        {rows.map((m) => {
          const gap = Number(m.invoiced) - Number(m.delivered)
          return (
            <tr key={m.month}>
              <td className="px-3 py-2 font-medium">{m.month}</td>
              <td className="px-3 py-2">{money(Number(m.delivered))}</td>
              <td className="px-3 py-2">{money(Number(m.invoiced))}</td>
              <td className={`px-3 py-2 ${Math.abs(gap) > 5000 ? 'font-semibold text-amber-700 dark:text-amber-300' : 'text-muted'}`}>
                {gap === 0 ? '—' : money(gap)}
              </td>
              <td className="px-3 py-2 text-muted">
                {m.cross_month_loads > 0 ? `${m.cross_month_loads} loads · ${money(Number(m.cross_month_amount))}` : '—'}
              </td>
            </tr>
          )
        })}
      </Table>
      {!anyDrift && <p className="mt-1 text-xs text-green-700 dark:text-green-300">Every load billed in its delivery month ✓</p>}
    </div>
  )
}

function ReportsTab() {
  const custQ = useQuery({ queryKey: ['acct-by-customer'], queryFn: () => acctRevenueByCustomer(365), retry: false })
  const marginQ = useQuery({ queryKey: ['acct-margin'], queryFn: () => acctMarginMonthly(12), retry: false })
  const margins = (marginQ.data ?? []).map((m) => ({ ...m, revenue: Number(m.revenue), margin: Number(m.margin) }))
  const custs = custQ.data ?? []
  return (
    <div className="space-y-6">
      <GlSection />
      <RevRecCard />
      <CreditMemoCard />
      <PaymentAuditCard />
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

import { useQuery } from '@tanstack/react-query'
import { Link, useParams } from 'react-router-dom'
import { Card, formatDate, LoadError, money, Table } from '../components/ui'
import { collectionsQueue, customerExposure, customerKeepFire, customerProfile } from '../data'

const VERDICT_STYLE: Record<string, string> = {
  grow: 'bg-emerald-500/15 text-emerald-700 dark:text-emerald-300',
  keep: 'bg-surface-2 text-muted',
  'fix-price': 'bg-amber-500/15 text-amber-700 dark:text-amber-300',
  fire: 'bg-red-500/15 text-red-700 dark:text-red-300',
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: string }) {
  return (
    <Card>
      <div className="text-xs font-semibold uppercase text-muted">{label}</div>
      <div className={`mt-1 text-2xl font-bold ${accent ?? 'text-body'}`}>{value}</div>
    </Card>
  )
}

/** The "should we keep hauling for these people" page. */
export default function CustomerDetail() {
  const { id } = useParams()
  const q = useQuery({
    queryKey: ['customer-profile', id],
    queryFn: () => customerProfile(Number(id)),
    enabled: !!id,
  })
  const exposureQ = useQuery({
    queryKey: ['customer-exposure', id],
    queryFn: () => customerExposure(Number(id)),
    enabled: !!id,
    retry: false,
  })
  const verdictQ = useQuery({
    queryKey: ['keep-fire'],
    queryFn: () => customerKeepFire(365),
    staleTime: 10 * 60 * 1000,
    retry: false,
  })
  const collectionsQ = useQuery({
    queryKey: ['collections-queue'],
    queryFn: collectionsQueue,
    staleTime: 5 * 60 * 1000,
    retry: false,
  })
  const verdict = verdictQ.data?.find((r) => r.customer_id === Number(id))
  const exposure = exposureQ.data
  const collections = collectionsQ.data?.find((r) => r.customer_id === Number(id))

  if (q.isError) return <LoadError error={q.error} onRetry={() => q.refetch()} />
  if (!q.data) return <p className="py-8 text-center text-muted">Loading…</p>
  if (!q.data.found) return <p className="py-8 text-center text-muted">Customer not found.</p>

  const p = q.data
  const c = p.customer
  const t = p.totals
  const marginTone =
    t.margin_pct_12m == null ? undefined : Number(t.margin_pct_12m) < 0 ? 'text-rose-600 dark:text-rose-400' : Number(t.margin_pct_12m) < 10 ? 'text-amber-600' : 'text-emerald-600 dark:text-emerald-400'

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <Link to="/customers" className="text-sm text-brand hover:underline">← Customers</Link>
          <h1 className="text-xl font-bold text-body">
            {c.company_name}
            {verdict && (
              <span
                className={`ml-2 rounded-full px-2 py-0.5 text-xs font-semibold ${VERDICT_STYLE[verdict.recommendation]}`}
                title={verdict.reason || undefined}
              >
                {verdict.recommendation}
              </span>
            )}
            {c.do_not_use && (
              <span className="ml-2 rounded-full bg-red-100 px-2 py-0.5 text-xs font-semibold text-red-700 dark:bg-red-900/40 dark:text-red-300">Do Not Use</span>
            )}
            {!c.is_active && !c.do_not_use && <span className="ml-2 text-sm font-normal text-muted">(inactive)</span>}
          </h1>
          <p className="text-sm text-muted">
            {[c.contact_person, c.phone, c.email, c.payment_terms].filter(Boolean).join(' · ') || 'No contact details'}
          </p>
        </div>
        {t.first_load && (
          <span className="text-xs text-muted">
            Hauling for them since {new Date(t.first_load + 'T00:00:00').toLocaleDateString()} · last load{' '}
            {t.last_load ? new Date(t.last_load + 'T00:00:00').toLocaleDateString() : '—'}
          </span>
        )}
      </div>

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Stat label="Revenue (12 mo)" value={money(t.revenue_12m ?? 0)} accent="text-brand" />
        <Stat
          label={`Margin (12 mo, at $${Number(p.all_in_rpm_basis).toFixed(2)}/mi all-in)`}
          value={t.margin_pct_12m != null ? `${money(t.est_margin_12m ?? 0)} (${t.margin_pct_12m}%)` : '—'}
          accent={marginTone}
        />
        <Stat label="Avg days to pay" value={p.pay.avg_days_to_pay != null ? `${Math.round(Number(p.pay.avg_days_to_pay))}d` : 'no history'} />
        <Stat
          label="Open AR (outstanding)"
          value={money(p.pay.open_outstanding)}
          accent={Number(p.pay.past_due_outstanding) > 0 ? 'text-rose-600 dark:text-rose-400' : undefined}
        />
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Monthly trend (12 mo)">
          {p.monthly.length === 0 ? (
            <p className="py-4 text-center text-sm text-muted">No completed loads in the last 12 months.</p>
          ) : (
            <Table headers={['Month', 'Loads', 'Revenue', '$/mi']}>
              {p.monthly.map((m) => (
                <tr key={m.month}>
                  <td className="px-3 py-2 font-medium">{m.month}</td>
                  <td className="px-3 py-2">{m.loads}</td>
                  <td className="px-3 py-2">{money(m.revenue)}</td>
                  <td className="px-3 py-2">{m.rpm != null ? `$${Number(m.rpm).toFixed(2)}` : '—'}</td>
                </tr>
              ))}
            </Table>
          )}
        </Card>
        <Card title="Right now">
          <dl className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm">
            <div><dt className="text-muted">Open loads</dt><dd className="text-lg font-bold">{p.activity.open_loads}</dd></div>
            <div><dt className="text-muted">Completed, unbilled</dt>
              <dd className={`text-lg font-bold ${p.activity.unbilled_completed > 0 ? 'text-amber-600' : ''}`}>{p.activity.unbilled_completed}</dd></div>
            <div><dt className="text-muted">Open invoices</dt><dd className="text-lg font-bold">{p.pay.open_invoices}</dd></div>
            <div><dt className="text-muted">Past-due outstanding</dt>
              <dd className={`text-lg font-bold ${Number(p.pay.past_due_outstanding) > 0 ? 'text-rose-600 dark:text-rose-400' : ''}`}>{money(p.pay.past_due_outstanding)}</dd></div>
            <div><dt className="text-muted">Detention at their docks (45d)</dt><dd className="text-lg font-bold">{p.activity.detention_hours_45d}h</dd></div>
            <div><dt className="text-muted">Documents on file</dt><dd className="text-lg font-bold">{p.activity.documents}</dd></div>
          </dl>
          <p className="mt-3 text-[11px] text-muted">
            Loads: <Link className="text-brand hover:underline" to={`/loads?customer=${c.id}`}>view this customer&rsquo;s loads →</Link>
          </p>
        </Card>
      </div>

      {(exposure || collections) && (
        <div className="grid gap-4 lg:grid-cols-2">
          {exposure && (
            <Card title="Credit exposure">
              <div className="flex items-baseline gap-3">
                <span className={`text-2xl font-bold ${exposure.over_limit ? 'text-rose-600 dark:text-rose-400' : 'text-body'}`}>
                  {money(Number(exposure.exposure))}
                </span>
                <span className="text-sm text-muted">of a {money(Number(exposure.limit))} limit</span>
                {exposure.over_limit && (
                  <span className="rounded-full bg-red-500/15 px-2 py-0.5 text-xs font-semibold text-red-700 dark:text-red-300">over limit</span>
                )}
              </div>
              <div className="mt-2 h-2 overflow-hidden rounded-full bg-surface-2">
                <div
                  className={`h-full ${exposure.over_limit ? 'bg-rose-500' : Number(exposure.exposure) / Math.max(Number(exposure.limit), 1) > 0.75 ? 'bg-amber-500' : 'bg-emerald-500'}`}
                  style={{ width: `${Math.min(100, (Number(exposure.exposure) / Math.max(Number(exposure.limit), 1)) * 100)}%` }}
                />
              </div>
              <p className="mt-2 text-xs text-muted">
                {money(Number(exposure.open_ar))} open AR + {money(Number(exposure.unbilled))} unbilled +{' '}
                {money(Number(exposure.open_loads))} in motion. Rule: {exposure.rule}.
              </p>
            </Card>
          )}
          {collections && (
            <Card title="In collections">
              <p className="text-sm">
                <span className="font-semibold text-rose-600 dark:text-rose-400">{money(Number(collections.overdue_total))}</span>{' '}
                overdue across {collections.overdue_count} invoice{collections.overdue_count === 1 ? '' : 's'}, oldest{' '}
                {collections.oldest_days} days.
              </p>
              {collections.last_promise ? (
                <p className="mt-2 text-sm text-muted">
                  Latest promise: {collections.last_promise.note}
                  {collections.last_promise.promised_amount != null && ` — ${money(Number(collections.last_promise.promised_amount))}`}
                  {collections.last_promise.promised_date && ` by ${formatDate(collections.last_promise.promised_date)}`}
                </p>
              ) : (
                <p className="mt-2 text-sm text-muted">No promise on file — they're on the call list.</p>
              )}
              <p className="mt-2 text-[11px] text-muted">
                Work the queue: <Link className="text-brand hover:underline" to="/invoices?tab=collections">Collections tab →</Link>
              </p>
            </Card>
          )}
        </div>
      )}
    </div>
  )
}

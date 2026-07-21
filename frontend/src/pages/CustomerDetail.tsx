import { useQuery } from '@tanstack/react-query'
import { Link, useParams } from 'react-router-dom'
import { Card, LoadError, money, Table } from '../components/ui'
import { customerProfile } from '../data'

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
    </div>
  )
}

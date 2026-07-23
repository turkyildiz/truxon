/** Client-side invoice PDF generation with jsPDF — download or email-ready base64. */
import { jsPDF } from 'jspdf'
import autoTable from 'jspdf-autotable'
import { getCompanySettings, getInvoiceFull } from './data'

const NAVY = '#1e3a5f'

async function buildInvoicePdf(invoiceId: number): Promise<{ doc: jsPDF; invoiceNumber: string }> {
  const [inv, company] = await Promise.all([getInvoiceFull(invoiceId), getCompanySettings()])
  const doc = new jsPDF({ unit: 'pt', format: 'letter' })

  doc.setTextColor(NAVY)
  doc.setFontSize(22).setFont('helvetica', 'bold')
  doc.text(company.company_name, 54, 60)
  doc.setFontSize(8).setFont('helvetica', 'normal').setTextColor('#555555')
  const companyLine = [company.address.replace(/\n/g, ', '), company.phone, company.mc_number && `MC# ${company.mc_number}`]
    .filter(Boolean)
    .join('  ·  ')
  if (companyLine) doc.text(companyLine, 54, 72)
  doc.setTextColor(NAVY).setFont('helvetica', 'bold')
  doc.setFontSize(14)
  doc.text(`INVOICE ${inv.invoice_number}`, 54, 92)

  doc.setTextColor('#000000').setFontSize(10).setFont('helvetica', 'normal')
  const lines = [
    `Bill To: ${inv.customer.company_name}`,
    ...String(inv.customer.billing_address ?? '').split('\n').filter(Boolean),
    `Date: ${new Date(inv.invoice_date).toLocaleDateString()}`,
    ...(inv.due_date ? [`Due: ${new Date(inv.due_date).toLocaleDateString()}`] : []),
    `Terms: ${inv.customer.payment_terms}`,
  ]
  lines.forEach((line, i) => doc.text(line, 54, 118 + i * 14))

  const money = (n: number) => `$${Number(n).toLocaleString('en-US', { minimumFractionDigits: 2 })}`
  const loadNumberById = new Map(inv.loads.map((l) => [l.id, l.load_number]))
  const body = inv.loads.map((l: { load_number: string; pickup_address: string; delivery_address: string; miles: number; rate: number }) => [
    l.load_number,
    (l.pickup_address ?? '').slice(0, 40),
    (l.delivery_address ?? '').slice(0, 40),
    Number(l.miles).toLocaleString(),
    l.miles > 0 ? money(l.rate / l.miles) : '—',
    money(l.rate),
  ])
  // Accessorial lines (detention etc.) — without these the table doesn't sum
  // to the billed total.
  const accessorials = inv.accessorials ?? []
  for (const a of accessorials) {
    body.push([
      loadNumberById.get(a.load_id) ?? `#${a.load_id}`,
      `${a.atype === 'detention' ? 'Detention' : a.atype}${a.stop_type ? ` — ${a.stop_type}` : ''}`,
      a.minutes != null ? `${Math.floor(a.minutes / 60)}h ${a.minutes % 60}m over free time` : '',
      '', '',
      money(a.amount),
    ])
  }

  autoTable(doc, {
    startY: 128 + lines.length * 14,
    head: [['Load #', 'Pickup', 'Delivery', 'Miles', 'Rate/Mile', 'Amount']],
    body,
    foot: [['', '', '', '', 'TOTAL', money(inv.total)]],
    styles: { fontSize: 8 },
    headStyles: { fillColor: NAVY },
    footStyles: { fillColor: '#f0f4f8', textColor: '#000000', fontStyle: 'bold' },
  })

  // Detention exhibit: the banked ELD proof, printed with the charge so a
  // dispute is answered before it starts.
  const withEvidence = accessorials.filter((a) => a.atype === 'detention' && a.evidence)
  if (withEvidence.length > 0) {
    const lastY = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY
    doc.setFontSize(8).setFont('helvetica', 'bold').setTextColor(NAVY)
    doc.text('Detention record (ELD telematics)', 54, lastY + 18)
    doc.setFont('helvetica', 'normal').setTextColor('#555555')
    withEvidence.forEach((a, i) => {
      const e = a.evidence!
      const fmt = (s: string) => new Date(s).toLocaleString('en-US', { dateStyle: 'short', timeStyle: 'short' })
      doc.text(
        `${loadNumberById.get(a.load_id) ?? `#${a.load_id}`} ${a.stop_type ?? ''}: arrived ${fmt(e.arrival)}, departed ${fmt(e.departure)}` +
          ` — ${Math.floor(e.dwell_min / 60)}h ${e.dwell_min % 60}m on site, ${e.free_min / 60}h free, ${e.detention_min} min billable.`,
        54, lastY + 30 + i * 11,
      )
    })
  }

  return { doc, invoiceNumber: inv.invoice_number }
}

export async function downloadInvoicePdf(invoiceId: number): Promise<void> {
  const { doc, invoiceNumber } = await buildInvoicePdf(invoiceId)
  doc.save(`${invoiceNumber}.pdf`)
}

/** The same PDF as base64 — what the invoice-send function emails to the broker. */
export async function invoicePdfBase64(invoiceId: number): Promise<string> {
  const { doc } = await buildInvoicePdf(invoiceId)
  return doc.output('datauristring').split(',')[1]
}

/** Monthly customer statement: every open (unfactored) invoice with aging
 * buckets and a total — the page you print or attach to a collections email. */
export async function buildCustomerStatement(customerId: number): Promise<{ doc: jsPDF; customerName: string } | null> {
  const [company, { supabase }] = await Promise.all([getCompanySettings(), import('./supabase')])
  const { data: cust } = await supabase
    .from('customers').select('company_name, billing_address').eq('id', customerId).single()
  const { data: invs } = await supabase
    .from('invoices')
    .select('invoice_number, invoice_date, due_date, total, qbo_balance, status, factored_at')
    .eq('customer_id', customerId).eq('status', 'sent').is('factored_at', null)
    .order('invoice_date')
  if (!cust || !invs || invs.length === 0) return null

  const money = (n: number) => `$${Number(n).toLocaleString('en-US', { minimumFractionDigits: 2 })}`
  const doc = new jsPDF({ unit: 'pt', format: 'letter' })
  const NAVY2 = '#1e3a5f'
  doc.setTextColor(NAVY2).setFontSize(22).setFont('helvetica', 'bold')
  doc.text(company.company_name, 54, 60)
  doc.setFontSize(8).setFont('helvetica', 'normal').setTextColor('#555555')
  const companyLine = [company.address.replace(/\n/g, ', '), company.phone, company.mc_number && `MC# ${company.mc_number}`]
    .filter(Boolean).join('  ·  ')
  if (companyLine) doc.text(companyLine, 54, 72)
  doc.setTextColor(NAVY2).setFont('helvetica', 'bold').setFontSize(14)
  doc.text('STATEMENT OF ACCOUNT', 54, 92)
  doc.setTextColor('#000000').setFontSize(10).setFont('helvetica', 'normal')
  const head = [
    `To: ${cust.company_name}`,
    ...String(cust.billing_address ?? '').split('\n').filter(Boolean),
    `As of: ${new Date().toLocaleDateString()}`,
  ]
  head.forEach((line, i) => doc.text(line, 54, 112 + i * 14))

  const days = (d: string | null) => (d ? Math.max(0, Math.floor((Date.now() - new Date(d).getTime()) / 864e5)) : 0)
  const bal = (r: { qbo_balance: number | null; total: number }) => Number(r.qbo_balance ?? r.total)
  const buckets = { current: 0, d30: 0, d60: 0, d90: 0, over: 0 }
  const body = invs.map((r) => {
    const overdue = days(r.due_date)
    const b = bal(r)
    if (overdue <= 0) buckets.current += b
    else if (overdue <= 30) buckets.d30 += b
    else if (overdue <= 60) buckets.d60 += b
    else if (overdue <= 90) buckets.d90 += b
    else buckets.over += b
    return [
      r.invoice_number,
      new Date(r.invoice_date).toLocaleDateString(),
      r.due_date ? new Date(r.due_date).toLocaleDateString() : '—',
      overdue > 0 ? `${overdue}d overdue` : 'current',
      money(b),
    ]
  })
  const total = invs.reduce((s, r) => s + bal(r), 0)
  autoTable(doc, {
    startY: 112 + head.length * 14 + 12,
    head: [['Invoice', 'Date', 'Due', 'Status', 'Balance']],
    body,
    foot: [['', '', '', 'TOTAL DUE', money(total)]],
    styles: { fontSize: 9 },
    headStyles: { fillColor: NAVY2 },
    footStyles: { fillColor: '#f0f4f8', textColor: '#000000', fontStyle: 'bold' },
  })
  const lastY = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY
  doc.setFontSize(9).setFont('helvetica', 'bold').setTextColor(NAVY2)
  doc.text('Aging', 54, lastY + 20)
  doc.setFont('helvetica', 'normal').setTextColor('#000000')
  doc.text(
    `Current ${money(buckets.current)}   ·   1-30d ${money(buckets.d30)}   ·   31-60d ${money(buckets.d60)}` +
      `   ·   61-90d ${money(buckets.d90)}   ·   90+d ${money(buckets.over)}`,
    54, lastY + 34,
  )
  return { doc, customerName: cust.company_name }
}

export async function downloadCustomerStatement(customerId: number): Promise<void> {
  const res = await buildCustomerStatement(customerId)
  if (!res) return
  const stamp = new Date().toISOString().slice(0, 7)
  res.doc.save(`statement-${res.customerName.replace(/\W+/g, '-')}-${stamp}.pdf`)
}

/** IFTA quarterly close package: per-jurisdiction miles + gallons with the
 * coverage honesty printed on the page (R9 #62). */
export async function downloadIftaPackage(
  quarter: string,
  rows: { jurisdiction: string; miles: number; share_pct: number; gallons: number; fuel_spend: number }[],
): Promise<void> {
  const [company, { supabase }] = await Promise.all([getCompanySettings(), import('./supabase')])
  const { data: status } = await supabase.rpc('ifta_miles_status')
  const st = (status ?? {}) as { days_banked?: number; first_day?: string; trucks_covered?: number; state_attributed_pct?: number }

  const money2 = (n: number) => `$${Number(n).toLocaleString('en-US', { minimumFractionDigits: 2 })}`
  const doc = new jsPDF({ unit: 'pt', format: 'letter' })
  const NAVY3 = '#1e3a5f'
  doc.setTextColor(NAVY3).setFontSize(22).setFont('helvetica', 'bold')
  doc.text(company.company_name, 54, 60)
  doc.setFontSize(8).setFont('helvetica', 'normal').setTextColor('#555555')
  const line = [company.address.replace(/\n/g, ', '), company.mc_number && `MC# ${company.mc_number}`].filter(Boolean).join('  ·  ')
  if (line) doc.text(line, 54, 72)
  doc.setTextColor(NAVY3).setFont('helvetica', 'bold').setFontSize(14)
  doc.text(`IFTA CLOSE PACKAGE — ${quarter}`, 54, 94)
  doc.setTextColor('#555555').setFontSize(8).setFont('helvetica', 'normal')
  doc.text(
    `Miles: GPS-banked ELD breadcrumbs attributed by state polygon (bank since ${st.first_day ?? '?'}, ` +
      `${st.days_banked ?? '?'} days, ${st.trucks_covered ?? '?'} trucks, ${st.state_attributed_pct ?? '?'}% attributed). ` +
      `Gallons/spend: card purchases in that state. Prepared ${new Date().toLocaleDateString()}.`,
    54, 108, { maxWidth: 500 },
  )

  const totMiles = rows.reduce((s, r) => s + Number(r.miles), 0)
  const totGal = rows.reduce((s, r) => s + Number(r.gallons), 0)
  const totSpend = rows.reduce((s, r) => s + Number(r.fuel_spend), 0)
  autoTable(doc, {
    startY: 126,
    head: [['Jurisdiction', 'Miles', 'Share %', 'Gallons bought', 'Fuel spend']],
    body: rows.map((r) => [
      r.jurisdiction || 'unattributed',
      Math.round(Number(r.miles)).toLocaleString(),
      Number(r.share_pct).toFixed(1),
      Number(r.gallons) > 0 ? Number(r.gallons).toLocaleString(undefined, { maximumFractionDigits: 1 }) : '—',
      Number(r.fuel_spend) > 0 ? money2(Number(r.fuel_spend)) : '—',
    ]),
    foot: [[
      'TOTAL', Math.round(totMiles).toLocaleString(), '100.0',
      totGal.toLocaleString(undefined, { maximumFractionDigits: 1 }), money2(totSpend),
    ]],
    styles: { fontSize: 9 },
    headStyles: { fillColor: NAVY3 },
    footStyles: { fillColor: '#f0f4f8', textColor: '#000000', fontStyle: 'bold' },
  })
  const lastY = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY
  doc.setFontSize(9).setFont('helvetica', 'normal').setTextColor('#000000')
  if (totGal > 0 && totMiles > 0) {
    doc.text(`Fleet average: ${(totMiles / totGal).toFixed(2)} MPG over the covered window.`, 54, lastY + 20)
  }
  doc.setTextColor('#555555').setFontSize(8)
  doc.text(
    'File with your base jurisdiction; keep this package with the quarter’s fuel receipts. ' +
      'Days before the GPS bank began are not represented in the miles column.',
    54, lastY + 34, { maxWidth: 500 },
  )
  doc.save(`ifta-${quarter.replace(/\s+/g, '')}.pdf`)
}

/** Monthly owner package (R9 #167): one printable PDF — P&L from the books,
 * receivables, ops, safety, and the playbook movers — composed entirely from
 * the report functions the app already trusts. */
export async function downloadMonthlyPackage(): Promise<void> {
  const [company, { supabase }] = await Promise.all([getCompanySettings(), import('./supabase')])
  const call = async (fn: string, args?: Record<string, unknown>) =>
    (await supabase.rpc(fn as never, args as never)).data as unknown
  const monthStart = new Date()
  monthStart.setDate(1); monthStart.setHours(0, 0, 0, 0)
  const [pnl, cfo, acct, score, trends] = await Promise.all([
    call('gl_pnl_monthly', { p_months: 6 }) as Promise<Record<string, unknown>[] | null>,
    call('gl_cfo_snapshot') as Promise<Record<string, unknown> | null>,
    call('acct_summary') as Promise<Record<string, unknown> | null>,
    call('company_scorecard', { p_start: monthStart.toISOString(), p_end: new Date().toISOString() }) as Promise<Record<string, unknown> | null>,
    call('metric_trends', { p_prefix: null }) as Promise<Record<string, unknown>[] | null>,
  ])

  const money2 = (n: unknown) => n == null ? '—' : `$${Number(n).toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`
  const pct = (n: unknown) => n == null ? '—' : `${Number(n)}%`
  const doc = new jsPDF({ unit: 'pt', format: 'letter' })
  const NAVY4 = '#1e3a5f'
  doc.setTextColor(NAVY4).setFontSize(22).setFont('helvetica', 'bold')
  doc.text(company.company_name, 54, 60)
  doc.setFont('helvetica', 'bold').setFontSize(14)
  doc.text(`OWNER PACKAGE — ${new Date().toLocaleDateString(undefined, { month: 'long', year: 'numeric' })}`, 54, 84)
  doc.setFontSize(8).setFont('helvetica', 'normal').setTextColor('#555555')
  doc.text(`Prepared ${new Date().toLocaleString()} from the live books and telematics. Month-to-date where marked.`, 54, 98)

  // P&L (GL mirror)
  autoTable(doc, {
    startY: 116,
    head: [['Month', 'Income', 'Net income', 'Net %', 'Operating ratio']],
    body: (pnl ?? []).map((m) => [
      String(m.month), money2(m.income), money2(m.net_income), pct(m.net_margin_pct), pct(m.operating_ratio),
    ]),
    styles: { fontSize: 9 }, headStyles: { fillColor: NAVY4 },
  })
  let y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 16

  // Cash + receivables strip
  doc.setFontSize(11).setFont('helvetica', 'bold').setTextColor(NAVY4)
  doc.text('Cash & receivables', 54, y)
  doc.setFontSize(9).setFont('helvetica', 'normal').setTextColor('#000000')
  const cashLines = [
    `Cash on hand ${money2(cfo?.cash)} (${cfo?.days_of_cash ?? '—'} days of cost) · Current ratio ${cfo?.current_ratio ?? '—'}`,
    `AR outstanding ${money2(acct?.ar_total)} · past due ${money2(acct?.past_due_total)} · DSO ${acct?.dso_days ?? '—'}d · unbilled ${money2(acct?.unbilled_total)}`,
    `True operating ratio (equipment-adjusted) ${pct(cfo?.operating_ratio_equip_adj)}${Number(cfo?.equipment_gap_12m) > 0 ? ` — includes ${money2(cfo?.equipment_gap_12m)}/yr of payments the GL can't see` : ''}`,
  ]
  cashLines.forEach((l, i) => doc.text(l, 54, y + 14 + i * 13))
  y += 14 + cashLines.length * 13 + 10

  // Ops + safety (month to date)
  const ops = (score as Record<string, Record<string, unknown>> | null)?.operations
  const saf = (score as Record<string, Record<string, unknown>> | null)?.safety
  doc.setFontSize(11).setFont('helvetica', 'bold').setTextColor(NAVY4)
  doc.text('Operations & safety — month to date', 54, y)
  doc.setFontSize(9).setFont('helvetica', 'normal').setTextColor('#000000')
  const opsLines = [
    `Loads ${ops?.loads ?? '—'} · miles ${ops?.total_miles ?? '—'} · on-time delivery ${pct(ops?.on_time_delivery_pct)} · empty miles ${ops?.empty_miles ?? '—'}`,
    `Accidents ${saf?.accidents_in_window ?? 0} · HOS violations ${saf?.hos_violations ?? 0} · OOS rate ${pct(saf?.oos_rate_pct)}`,
  ]
  opsLines.forEach((l, i) => doc.text(l, 54, y + 14 + i * 13))
  y += 14 + opsLines.length * 13 + 10

  // Playbook movers (biggest WoW swings)
  const movers = (trends ?? [])
    .filter((t) => t.wow_pct != null && Math.abs(Number(t.wow_pct)) >= 10 && Number(t.points) >= 3)
    .sort((a, b) => Math.abs(Number(b.wow_pct)) - Math.abs(Number(a.wow_pct)))
    .slice(0, 8)
  if (movers.length > 0) {
    autoTable(doc, {
      startY: y,
      head: [['Metric mover', 'Latest', 'WoW change', '13-week slope']],
      body: movers.map((t) => [
        String(t.metric_key), String(Math.round(Number(t.latest) * 10) / 10),
        `${Number(t.wow_pct) > 0 ? '+' : ''}${Math.round(Number(t.wow_pct))}%`,
        t.slope_13w != null ? String(Math.round(Number(t.slope_13w) * 100) / 100) : '—',
      ]),
      styles: { fontSize: 8 }, headStyles: { fillColor: NAVY4 },
    })
  }
  doc.save(`owner-package-${new Date().toISOString().slice(0, 7)}.pdf`)
}

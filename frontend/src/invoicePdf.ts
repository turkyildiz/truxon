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

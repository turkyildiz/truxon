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

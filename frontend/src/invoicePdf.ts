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
  const body = inv.loads.map((l: { load_number: string; pickup_address: string; delivery_address: string; miles: number; rate: number }) => [
    l.load_number,
    (l.pickup_address ?? '').slice(0, 40),
    (l.delivery_address ?? '').slice(0, 40),
    Number(l.miles).toLocaleString(),
    l.miles > 0 ? money(l.rate / l.miles) : '—',
    money(l.rate),
  ])

  autoTable(doc, {
    startY: 128 + lines.length * 14,
    head: [['Load #', 'Pickup', 'Delivery', 'Miles', 'Rate/Mile', 'Amount']],
    body,
    foot: [['', '', '', '', 'TOTAL', money(inv.total)]],
    styles: { fontSize: 8 },
    headStyles: { fillColor: NAVY },
    footStyles: { fillColor: '#f0f4f8', textColor: '#000000', fontStyle: 'bold' },
  })

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

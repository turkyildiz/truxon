// Email an invoice PDF to the customer's billing address, from the Trux
// mailbox — Truxon as the complete billing system (no QuickBooks needed).
// The frontend generates the PDF it already renders for download and POSTs it
// here; we validate the caller is admin, resolve the recipient, send via
// Graph, stamp sent_at/sent_to, log the activity, and flip draft → sent.
//
// POST { invoice_id, pdf_base64, to? }   (to overrides the customer email)
import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json, withCors } from '../_shared/auth.ts'
import { graphConfigured, graphToken, sendMailWithAttachment, TRUX_MAILBOX } from '../_shared/msgraph.ts'

const MAX_PDF_BYTES = 5 * 1024 * 1024 // base64 of a ~3.7MB pdf

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const caller = await getCaller(req)
  if (caller instanceof Response) return caller
  if (caller.role !== 'admin') return json({ error: 'Admin only' }, 403)

  if (!graphConfigured()) return json({ error: 'Email is not configured (MSGRAPH secrets missing)' }, 500)

  let body: { invoice_id?: number; pdf_base64?: string; to?: string } = {}
  try { body = await req.json() } catch { /* fallthrough */ }
  const invoiceId = Number(body.invoice_id)
  const pdf = String(body.pdf_base64 ?? '')
  if (!invoiceId || !pdf) return json({ error: 'invoice_id and pdf_base64 required' }, 422)
  if (pdf.length > MAX_PDF_BYTES) return json({ error: 'PDF too large' }, 413)

  const s = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: inv } = await s.from('invoices')
    .select('id, invoice_number, total, due_date, status, customer:customers(company_name, email, secondary_email)')
    .eq('id', invoiceId).single()
  if (!inv) return json({ error: 'Invoice not found' }, 404)
  if (inv.status === 'void') return json({ error: 'Cannot send a void invoice' }, 422)

  // deno-lint-ignore no-explicit-any
  const cust = inv.customer as any
  const to = String(body.to ?? cust?.email ?? '').trim()
  if (!to || !to.includes('@')) {
    return json({ error: `No billing email on file for ${cust?.company_name ?? 'this customer'} — add one on the Customers page or pass "to"` }, 422)
  }

  const dueTxt = inv.due_date ? new Date(inv.due_date).toLocaleDateString('en-US') : ''
  const subject = `Invoice ${inv.invoice_number} — Aida Logistics LLC`
  const text = [
    `Hello,`,
    ``,
    `Please find attached invoice ${inv.invoice_number} for $${Number(inv.total).toLocaleString('en-US', { minimumFractionDigits: 2 })}.`,
    dueTxt ? `Payment is due by ${dueTxt}.` : '',
    ``,
    `Reply to this email with any questions.`,
    ``,
    `Aida Logistics LLC`,
    TRUX_MAILBOX,
  ].filter((l) => l !== null).join('\n')

  const tok = await graphToken()
  const sent = await sendMailWithAttachment(tok, [to], subject, text, `${inv.invoice_number}.pdf`, pdf)
  if (!sent.ok) {
    return json({ error: `Email send failed (${sent.status}): ${sent.detail ?? 'unknown'}` }, 502)
  }

  const patch: Record<string, unknown> = { sent_at: new Date().toISOString(), sent_to: to }
  if (inv.status === 'draft') patch.status = 'sent'
  await s.from('invoices').update(patch).eq('id', invoiceId)
  await s.from('activity_log').insert({
    entity_type: 'invoice', entity_id: invoiceId, user_id: caller.userId,
    action: 'invoice_emailed', detail: `${inv.invoice_number} emailed to ${to}`,
  })

  return json({ ok: true, to })
}))

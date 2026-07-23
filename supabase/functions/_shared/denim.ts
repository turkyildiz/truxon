// Pure reconcile logic for denim-sync, extracted so it can be unit-tested
// without Deno.serve/network: invoice-reference indexing, job→invoice
// matching, fee math (Denim sends cents), and the metadata patch.

export interface DenimObligation {
  type?: string
  subtype?: string                 // live payloads: type 'earnings' + subtype 'factoring_fee'/'servicing_fee'
  total_amount?: number            // cents
  payment_status?: string
  line_items?: Array<{ amount?: number; type?: string }>
}
export interface DenimJob {
  id?: string | number
  uuid?: string
  job_id?: string | number
  reference_number?: string | null
  status?: string
  created_at?: string
  obligations?: DenimObligation[]
  receivable?: DenimObligation
  fees?: DenimObligation[]
}
export interface InvoiceRow extends Record<string, unknown> {
  id: number
  invoice_number?: string | null
  qbo_doc_number?: string | null
  factored_at?: string | null
  factoring_fee?: number | null
}

export const digits = (s: string) => s.replace(/\D+/g, '')

/** Index invoices by exact (lowercased) number AND digits-only form; the
 * digits key never overwrites an earlier exact-length claim (first wins). */
export function buildInvoiceIndex(invs: InvoiceRow[]): Map<string, InvoiceRow> {
  const byRef = new Map<string, InvoiceRow>()
  for (const i of invs) {
    for (const k of [i.invoice_number, i.qbo_doc_number]) {
      const s = String(k ?? '').trim()
      if (!s) continue
      byRef.set(s.toLowerCase(), i)
      const d = digits(s)
      if (d.length >= 3 && !byRef.has(d)) byRef.set(d, i)
    }
  }
  return byRef
}

/** Match a Denim reference to an invoice: exact first, digits fallback. */
export function matchJob(byRef: Map<string, InvoiceRow>, ref: string): InvoiceRow | undefined {
  return byRef.get(ref.toLowerCase()) ?? byRef.get(digits(ref))
}

/** Fee dollars (Denim sends cents). Live payloads carry fees as
 * type 'earnings' + subtype 'factoring_fee'/'servicing_fee', so match on
 * either field — type-only missed every real fee. */
export function jobFee(j: DenimJob): number | null {
  const obls: DenimObligation[] = [
    ...(Array.isArray(j.obligations) ? j.obligations : []),
    ...(Array.isArray(j.fees) ? j.fees : []),
  ]
  const feeCents = obls
    .filter((o) => /fee/i.test(String(o.type ?? '')) || /fee/i.test(String(o.subtype ?? '')))
    .reduce((s, o) => s + (Number(o.total_amount) || 0), 0)
  return feeCents > 0 ? Math.round(feeCents) / 100 : null
}

/** Receivable dollars (the invoice face Denim is financing); cents in. */
export function jobReceivable(j: DenimJob): number | null {
  const obls: DenimObligation[] = Array.isArray(j.obligations) ? j.obligations : []
  let cents = obls
    .filter((o) => /receivable|invoice/i.test(String(o.type ?? '')) || /receivable|invoice/i.test(String(o.subtype ?? '')))
    .reduce((s, o) => s + (Number(o.total_amount) || 0), 0)
  if (!cents && j.receivable) cents = Number(j.receivable.total_amount) || 0
  return cents > 0 ? Math.round(cents) / 100 : null
}

/** The metadata-only invoice patch. Never rewrites an existing factored_at;
 * only touches factoring_fee when the value actually changes. */
export function jobPatch(j: DenimJob, inv: InvoiceRow): { patch: Record<string, unknown>; feeChanged: boolean } {
  const fee = jobFee(j)
  // live pull showed 350 matches but denim_job_id stayed '' — the payload
  // doesn't use `id`; accept the known aliases before giving up
  const jobId = j.id ?? j.uuid ?? j.job_id ?? ''
  const patch: Record<string, unknown> = { denim_job_id: String(jobId), factor_name: 'Denim' }
  if (!inv.factored_at) patch.factored_at = j.created_at ?? new Date().toISOString()
  let feeChanged = false
  if (fee != null && Number(inv.factoring_fee ?? 0) !== fee) {
    patch.factoring_fee = fee
    feeChanged = true
  }
  return { patch, feeChanged }
}

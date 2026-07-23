// deno test supabase/functions/_shared/denim.test.ts
import { assertEquals } from 'jsr:@std/assert@1'
import { buildInvoiceIndex, type InvoiceRow, jobFee, jobPatch, jobReceivable, matchJob } from './denim.ts'

const inv = (id: number, num: string, extra: Partial<InvoiceRow> = {}): InvoiceRow =>
  ({ id, invoice_number: num, qbo_doc_number: null, factored_at: null, factoring_fee: null, ...extra })

Deno.test('exact reference match is case-insensitive', () => {
  const byRef = buildInvoiceIndex([inv(1, 'INV-2026-041')])
  assertEquals(matchJob(byRef, 'inv-2026-041')?.id, 1)
})

Deno.test('digits-normalized fallback matches decorated references', () => {
  const byRef = buildInvoiceIndex([inv(2, 'INV-2026-052')])
  assertEquals(matchJob(byRef, '#2026 / 052')?.id, 2)
  assertEquals(matchJob(byRef, 'totally-different'), undefined)
})

Deno.test('qbo doc number is a first-class match key', () => {
  const byRef = buildInvoiceIndex([inv(3, 'INV-2026-001', { qbo_doc_number: '1088' })])
  assertEquals(matchJob(byRef, '1088')?.id, 3)
})

Deno.test('fee sums only fee-type obligations, cents to dollars', () => {
  assertEquals(
    jobFee({
      obligations: [
        { type: 'receivable', total_amount: 250_000 },
        { type: 'factoring_fee', total_amount: 7_500 },
      ],
      fees: [{ type: 'wire_fee', total_amount: 1_500 }],
    }),
    90, // (7500 + 1500) cents
  )
  assertEquals(jobFee({ obligations: [{ type: 'receivable', total_amount: 250_000 }] }), null)
})

Deno.test('patch backfills factored_at only when the invoice has none', () => {
  const fresh = jobPatch({ uuid: 'j-9', created_at: '2026-07-01T00:00:00Z' }, inv(4, 'INV-2026-004'))
  assertEquals(fresh.patch.factored_at, '2026-07-01T00:00:00Z')
  assertEquals(fresh.patch.denim_job_id, 'j-9') // uuid alias accepted
  const already = jobPatch(
    { uuid: 'j-9', created_at: '2026-07-01T00:00:00Z' },
    inv(5, 'INV-2026-005', { factored_at: '2026-06-01T00:00:00Z' }),
  )
  assertEquals('factored_at' in already.patch, false)
})

Deno.test('fee only patched on change', () => {
  const job = { fees: [{ type: 'fee', total_amount: 5_000 }] }
  const changed = jobPatch(job, inv(6, 'A'))
  assertEquals(changed.feeChanged, true)
  assertEquals(changed.patch.factoring_fee, 50)
  const same = jobPatch(job, inv(7, 'B', { factoring_fee: 50 }))
  assertEquals(same.feeChanged, false)
  assertEquals('factoring_fee' in same.patch, false)
})

Deno.test('receivable: obligation-typed, top-level fallback, cents to dollars', () => {
  assertEquals(jobReceivable({ obligations: [{ type: 'receivable', total_amount: 120_000 }] }), 1200)
  assertEquals(jobReceivable({ receivable: { total_amount: 95_050 } }), 950.5)
  assertEquals(jobReceivable({ obligations: [{ type: 'fee', total_amount: 5_000 }] }), null)
  assertEquals(jobReceivable({}), null)
})

Deno.test('live payload shape: earnings-type fees found via subtype', () => {
  const j = { obligations: [
    { type: 'earnings', subtype: 'factoring_fee', total_amount: 10_540 },
    { type: 'earnings', subtype: 'servicing_fee', total_amount: 295 },
  ] }
  assertEquals(jobFee(j), 108.35)
})

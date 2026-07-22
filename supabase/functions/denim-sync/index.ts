// Denim factoring sync — pulls Jobs (+ their receivable/fee obligations) from
// the Denim Public API and reconciles them onto Truxon invoices:
//   * match by reference_number == our invoice number (or QBO doc number)
//   * matched invoice -> factored (factored_at, factor_name, denim_job_id)
//   * fee obligations  -> invoices.factoring_fee (dollars; Denim sends cents)
// Conservative v1: METADATA ONLY — no payment rows are written and no status
// flips; QBO stays the money source of truth (its balance already reflects
// Denim's advances/releases via the books). Money-posting comes after we've
// seen real payloads.
//
// DORMANT until DENIM_API_KEY is set (returns {skipped}). DENIM_BASE_URL
// defaults to production; point it at https://staging.denim.com to test.
// Auth: cron secret (x-cron-key) or an admin session. 2h pg_cron drives it.

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json, requireCron, withCors } from '../_shared/auth.ts'

const BASE = (Deno.env.get('DENIM_BASE_URL') ?? 'https://app.denim.com').replace(/\/$/, '')

interface DenimObligation {
  type?: string
  total_amount?: number            // cents
  payment_status?: string
  line_items?: Array<{ amount?: number; type?: string }>
}
interface DenimJob {
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

const digits = (s: string) => s.replace(/\D+/g, '')

async function denim(path: string, key: string): Promise<Response> {
  return await fetch(`${BASE}${path}`, {
    headers: { 'x-api-key': key, 'Accept': 'application/json' },
    signal: AbortSignal.timeout(30_000),
  })
}

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()

  const isCron = requireCron(req)
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  if (!isCron) {
    const caller = await getCaller(req)
    if (caller instanceof Response) return caller
    if (caller.role !== 'admin') return json({ error: 'Not enough permissions' }, 403)
  }

  const key = Deno.env.get('DENIM_API_KEY')
  if (!key) return json({ skipped: 'no DENIM_API_KEY configured — sync dormant' })

  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  // ── status: connectivity + config probe, no writes ──
  if (body.mode === 'status') {
    const r = await denim('/api/v1/jobs?page=1&per_page=1', key)
    return json({
      base: BASE, reachable: r.ok, http: r.status,
      sample: r.ok ? await r.json().catch(() => null) : (await r.text()).slice(0, 300),
    })
  }

  // ── pull (default): jobs -> match -> factored metadata ──
  const stats = { pages: 0, jobs: 0, matched: 0, updated: 0, fees_set: 0, unmatched: [] as string[], job_keys: [] as string[] }
  const maxPages = Math.min(Number(body.pages) || 5, 20)
  const t0 = Date.now()

  // invoice lookup: number + qbo doc number, digits-normalized
  const { data: invs } = await svc.from('invoices')
    .select('id, invoice_number, qbo_doc_number, factored_at, factoring_fee, source, status')
  const byRef = new Map<string, Record<string, unknown>>()
  for (const i of invs ?? []) {
    for (const k of [i.invoice_number, i.qbo_doc_number]) {
      const s = String(k ?? '').trim()
      if (!s) continue
      byRef.set(s.toLowerCase(), i)
      const d = digits(s)
      if (d.length >= 3 && !byRef.has(d)) byRef.set(d, i)
    }
  }

  for (let page = 1; page <= maxPages; page++) {
    if (Date.now() - t0 > 100_000) break
    const r = await denim(`/api/v1/jobs?page=${page}&per_page=100`, key)
    if (!r.ok) return json({ error: `Denim ${r.status}: ${(await r.text()).slice(0, 200)}`, ...stats }, 502)
    const payload = await r.json() as Record<string, unknown>
    const jobs = (payload.data ?? payload.jobs ?? payload.results ?? payload) as DenimJob[]
    if (!Array.isArray(jobs) || jobs.length === 0) break
    if (!stats.job_keys.length && jobs[0]) stats.job_keys = Object.keys(jobs[0] as Record<string, unknown>)
    stats.pages++

    for (const j of jobs) {
      stats.jobs++
      const ref = String(j.reference_number ?? '').trim()
      if (!ref) continue
      const inv = byRef.get(ref.toLowerCase()) ?? byRef.get(digits(ref))
      if (!inv) { if (stats.unmatched.length < 20) stats.unmatched.push(ref); continue }
      stats.matched++

      // fee = sum of fee-type obligations (cents -> dollars)
      const obls: DenimObligation[] = [
        ...(Array.isArray(j.obligations) ? j.obligations : []),
        ...(Array.isArray(j.fees) ? j.fees : []),
      ]
      const feeCents = obls
        .filter((o) => /fee/i.test(String(o.type ?? '')))
        .reduce((s, o) => s + (Number(o.total_amount) || 0), 0)
      const fee = feeCents > 0 ? Math.round(feeCents) / 100 : null

      // live pull showed 350 matches but denim_job_id stayed '' — the payload
      // doesn't use `id`; accept the known aliases before giving up
      const jobId = j.id ?? j.uuid ?? j.job_id ?? ''
      const patch: Record<string, unknown> = { denim_job_id: String(jobId), factor_name: 'Denim' }
      if (!inv.factored_at) patch.factored_at = j.created_at ?? new Date().toISOString()
      if (fee != null && Number(inv.factoring_fee ?? 0) !== fee) { patch.factoring_fee = fee; stats.fees_set++ }
      const { error } = await svc.from('invoices').update(patch).eq('id', inv.id)
      if (!error) stats.updated++
    }
    const totalPages = Number((payload as Record<string, unknown>).total_pages) || page
    if (page >= totalPages) break
  }

  return json({ mode: 'pull', base: BASE, ...stats, unmatched_count: stats.unmatched.length })
}))

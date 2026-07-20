// Customer enrichment — Trux reads each customer's paperwork and fills the
// profile fields left blank at import time. Reuses the extract-pdf brain
// (unpdf text layer + LLM customer profile). Writes go ONLY through the
// apply_customer_enrichment RPC, which fills empty columns only and never
// touches company_name.
//
// Safety:
//  - admin-gated (getCaller role check)
//  - blanks-only writes enforced in SQL (the RPC), logged per field
//  - name-match guard: a document's contacts are used ONLY if the broker it
//    names matches this customer — so a mis-filed rate con can't poison another
//    customer's record
//  - cost-bounded: <= docsPerCustomer LLM calls per customer, <= limit customers
//    per call; the caller pages with a cursor (after_id) until processed === 0
//
// POST body: { after_id?, limit=25, docs_per_customer=3, apply=false, customer_id? }
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, LLM_API_KEY, LLM_MODEL

import { extractText, getDocumentProxy } from 'npm:unpdf@0.12.1'
import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json } from '../_shared/auth.ts'
import { customerPrompt, extractFields, sliceText } from '../_shared/extract_llm.ts'

const STOPWORDS = new Set([
  'inc', 'llc', 'ltd', 'co', 'corp', 'company', 'group', 'the', 'and', 'of',
  'logistics', 'transport', 'transportation', 'freight', 'trucking', 'carriers',
  'carrier', 'services', 'service', 'brokerage', 'solutions', 'intl', 'international', 'usa', 'dba',
])
const norm = (s: string) =>
  new Set(String(s ?? '').toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter((t) => t.length > 2 && !STOPWORDS.has(t)))
// Does the extracted broker name plausibly match this customer?
function nameMatches(customerName: string, extractedName: unknown): boolean {
  if (!extractedName) return false // can't confirm → don't trust the contacts
  const a = norm(customerName), b = norm(String(extractedName))
  if (a.size === 0 || b.size === 0) return false
  let hits = 0
  for (const t of b) if (a.has(t)) hits++
  return hits >= 1 // at least one significant shared token
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  const caller = await getCaller(req)
  if (caller instanceof Response) return caller
  if (caller.role !== 'admin') return json({ error: 'Not enough permissions' }, 403)

  const apiKey = Deno.env.get('LLM_API_KEY')
  if (!apiKey) return json({ error: 'No LLM API key configured' }, 400)
  const model = Deno.env.get('LLM_MODEL') ?? 'meta-llama/llama-3.1-8b-instruct'

  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  const afterId = Number(body.after_id) || 0
  const limit = Math.min(Math.max(Number(body.limit) || 25, 1), 50)
  const docsPerCustomer = Math.min(Math.max(Number(body.docs_per_customer) || 3, 1), 5)
  const apply = body.apply === true
  const oneCustomer = body.customer_id ? Number(body.customer_id) : null

  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: settings } = await svc.from('company_settings').select('company_name').eq('id', 1).maybeSingle()
  const carrier = settings?.company_name || 'the carrier'

  // Candidate customers: at least one of the extractable fields is blank.
  let q = svc.from('customers')
    .select('id, company_name, contact_person, phone, email, billing_address, notes')
    .or('contact_person.eq.,phone.eq.,email.eq.,billing_address.eq.')
    .order('id', { ascending: true })
    .limit(limit)
  if (oneCustomer) q = svc.from('customers').select('id, company_name, contact_person, phone, email, billing_address, notes').eq('id', oneCustomer)
  else q = q.gt('id', afterId)
  const { data: customers, error: custErr } = await q
  if (custErr) return json({ error: custErr.message }, 500)

  const report: Array<Record<string, unknown>> = []
  let lastId = afterId
  let filledTotal = 0

  for (const c of customers ?? []) {
    lastId = c.id as number
    // gather source docs: the customer's own attachments first, then recent
    // rate cons from this customer's loads. PDFs only (text-layer extraction).
    const docs: Array<{ id: number; storage_path: string; filename: string; content_type: string }> = []
    const { data: ownDocs } = await svc.from('documents')
      .select('id, storage_path, filename, content_type')
      .eq('entity_type', 'customer').eq('entity_id', c.id)
      .order('uploaded_at', { ascending: false }).limit(docsPerCustomer)
    for (const d of ownDocs ?? []) docs.push(d as typeof docs[number])
    if (docs.length < docsPerCustomer) {
      const { data: loads } = await svc.from('loads').select('id').eq('customer_id', c.id).limit(200)
      const loadIds = (loads ?? []).map((l) => l.id)
      if (loadIds.length) {
        const { data: loadDocs } = await svc.from('documents')
          .select('id, storage_path, filename, content_type')
          .eq('entity_type', 'load').in('entity_id', loadIds)
          .order('uploaded_at', { ascending: false }).limit(docsPerCustomer * 2)
        for (const d of loadDocs ?? []) { if (docs.length >= docsPerCustomer) break; docs.push(d as typeof docs[number]) }
      }
    }

    const merged: Record<string, string> = {}
    let sourceDocId: number | null = null
    let docsUsed = 0
    const skipped: string[] = []
    for (const d of docs) {
      if (!/pdf/i.test(d.content_type) && !/\.pdf$/i.test(d.filename)) { skipped.push(`${d.filename}: not a PDF`); continue }
      let text = ''
      try {
        const { data: blob, error: dlErr } = await svc.storage.from('documents').download(d.storage_path)
        if (dlErr || !blob) { skipped.push(`${d.filename}: download failed`); continue }
        const pdf = await getDocumentProxy(new Uint8Array(await blob.arrayBuffer()))
        text = (await extractText(pdf, { mergePages: true })).text
      } catch (e) { skipped.push(`${d.filename}: read error`); continue }
      if (!text.trim()) { skipped.push(`${d.filename}: scanned/no text layer`); continue }

      let fields: Record<string, unknown>
      try { fields = await extractFields(apiKey, model, customerPrompt(carrier) + '\n\nDocument text:\n' + sliceText(text)) }
      catch { skipped.push(`${d.filename}: extraction failed`); continue }

      // name-match guard — don't let a mis-filed doc poison this customer
      if (!nameMatches(c.company_name as string, fields.company_name)) { skipped.push(`${d.filename}: broker name mismatch`); continue }
      docsUsed++
      const mc = fields.mc_number ? `MC# ${String(fields.mc_number).trim()}` : ''
      const noteVal = [mc, fields.notes ? String(fields.notes).trim() : ''].filter(Boolean).join(' — ')
      const candidate: Record<string, unknown> = {
        contact_person: fields.contact_person, phone: fields.phone, email: fields.email,
        billing_address: fields.billing_address, notes: noteVal || null,
      }
      for (const [k, v] of Object.entries(candidate)) {
        const val = v == null ? '' : String(v).trim()
        if (val && !merged[k]) { merged[k] = val; if (sourceDocId == null) sourceDocId = d.id }
      }
    }

    // only propose fills for fields currently blank on the record
    const proposed: Record<string, string> = {}
    for (const [k, v] of Object.entries(merged)) {
      const cur = String((c as Record<string, unknown>)[k] ?? '').trim()
      if (!cur) proposed[k] = v
    }

    let filled = 0
    if (apply && Object.keys(proposed).length) {
      const { data: n, error: rpcErr } = await svc.rpc('apply_customer_enrichment', {
        p_customer_id: c.id, p_fields: proposed, p_source_document_id: sourceDocId, p_model: model,
      })
      if (rpcErr) { report.push({ id: c.id, company_name: c.company_name, error: rpcErr.message }); continue }
      filled = Number(n) || 0
      filledTotal += filled
    }
    report.push({ id: c.id, company_name: c.company_name, docsUsed, filled, proposed: Object.keys(proposed), skipped })
  }

  return json({
    processed: (customers ?? []).length,
    apply,
    lastId,
    filledTotal,
    customers: report,
  })
})

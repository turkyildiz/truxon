// Customer enrichment — Trux reads each customer's paperwork and fills the
// profile fields left blank at import time. Reuses the extract-pdf brain
// (unpdf text layer + LLM customer profile). Writes go ONLY through the
// apply_customer_enrichment RPC, which fills empty columns only and never
// touches company_name.
//
// Auth (verify_jwt is OFF; gated in-function):
//   - admin session (getCaller role check)  → single cursor-paged batch (UI)
//   - anon-bearer cron caller                → monthly maintenance sweep
//
// Safety:
//  - blanks-only writes enforced in SQL (the RPC), logged per field
//  - name-match guard: a document's contacts are used ONLY if the broker it
//    names matches this customer — so a mis-filed rate con can't poison another
//    customer's record
//  - cost/time-bounded: <= docsPerCustomer LLM calls per customer; the UI pages
//    with a cursor, the cron sweep loops under a wall-clock budget
//
// POST body: { after_id?, limit=25, docs_per_customer=3, apply=false, customer_id?, cron? }
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, LLM_API_KEY, LLM_MODEL

import { extractText, getDocumentProxy } from 'npm:unpdf@0.12.1'
import { createClient, SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json, requireCron, withCors } from '../_shared/auth.ts'
import { customerPrompt, extractFields, extractFieldsText, sliceText } from '../_shared/extract_llm.ts'
import { validateCarrierNumbers } from '../_shared/fmcsa.ts'

// Every mc_number / usdot_number passes through FMCSA verification before the
// blanks-only write. No key / not-found / name-mismatch -> the number is dropped.
const FMCSA_WEBKEY = Deno.env.get('FMCSA_WEBKEY') || ''

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
  for (const t of b) if (a.has(t)) return true
  return false
}

interface BatchOpts {
  afterId: number
  limit: number
  docsPerCustomer: number
  apply: boolean
  oneCustomer: number | null
  apiKey: string
  model: string
  carrier: string
  deadlineMs?: number
}

// Process one page of candidate customers. Returns the report + the last id seen.
// Stops early if `deadlineMs` is reached (PDF parse + LLM latency vary a lot, and
// edge functions hard-cap at ~150s) — the caller resumes from `lastId`.
async function runBatch(svc: SupabaseClient, o: BatchOpts) {
  let q = svc.from('customers')
    .select('id, company_name, contact_person, phone, email, billing_address, notes')
    .or('contact_person.eq.,phone.eq.,email.eq.,billing_address.eq.')
    .order('id', { ascending: true })
    .limit(o.limit)
  if (o.oneCustomer) {
    q = svc.from('customers').select('id, company_name, contact_person, phone, email, billing_address, notes').eq('id', o.oneCustomer)
  } else {
    q = q.gt('id', o.afterId)
  }
  const { data: customers, error } = await q
  if (error) throw new Error(error.message)

  const report: Array<Record<string, unknown>> = []
  const queried = (customers ?? []).length
  let lastId = o.afterId
  let filledTotal = 0
  let processed = 0

  for (const c of customers ?? []) {
    if (o.deadlineMs && Date.now() > o.deadlineMs) break // resume next call from lastId
    processed++
    // gather source docs: the customer's own attachments first, then recent
    // rate cons from this customer's loads. PDFs only (text-layer extraction).
    const docs: Array<{ id: number; storage_path: string; filename: string; content_type: string; size_bytes: number }> = []
    const { data: ownDocs } = await svc.from('documents')
      .select('id, storage_path, filename, content_type, size_bytes')
      .eq('entity_type', 'customer').eq('entity_id', c.id)
      .order('uploaded_at', { ascending: false }).limit(o.docsPerCustomer)
    for (const d of ownDocs ?? []) docs.push(d as typeof docs[number])
    if (docs.length < o.docsPerCustomer) {
      const { data: loads } = await svc.from('loads').select('id').eq('customer_id', c.id).limit(200)
      const loadIds = (loads ?? []).map((l) => l.id)
      if (loadIds.length) {
        const { data: loadDocs } = await svc.from('documents')
          .select('id, storage_path, filename, content_type, size_bytes')
          .eq('entity_type', 'load').in('entity_id', loadIds)
          .order('uploaded_at', { ascending: false }).limit(o.docsPerCustomer * 3)
        for (const d of loadDocs ?? []) { if (docs.length >= o.docsPerCustomer) break; docs.push(d as typeof docs[number]) }
      }
    }

    const merged: Record<string, string> = {}
    let sourceDocId: number | null = null
    let docsUsed = 0
    const skipped: string[] = []
    const conflicts: string[] = []
    // memory: what we already know to be true for this customer — the model
    // validates against it, and disagreements are surfaced, never written
    const known: Record<string, string> = {}
    for (const k of ['contact_person', 'phone', 'email', 'billing_address', 'mc_number', 'usdot_number']) {
      const val = String((c as Record<string, unknown>)[k] ?? '').trim()
      if (val) known[k] = val
    }
    for (const d of docs) {
      if (!/pdf/i.test(d.content_type) && !/\.pdf$/i.test(d.filename)) { skipped.push(`${d.filename}: not a PDF`); continue }
      // Big PDFs are almost always scanned images (no text layer) — parsing them
      // wastes ~a minute and yields nothing. Skip them fast.
      if (d.size_bytes && d.size_bytes > 4_000_000) { skipped.push(`${d.filename}: too large (likely scanned)`); continue }
      let text = ''
      try {
        const parse = (async () => {
          const { data: blob, error: dlErr } = await svc.storage.from('documents').download(d.storage_path)
          if (dlErr || !blob) throw new Error('download failed')
          const pdf = await getDocumentProxy(new Uint8Array(await blob.arrayBuffer()))
          return (await extractText(pdf, { mergePages: true })).text
        })()
        // hard cap per doc so a slow/scanned PDF can't blow the wall clock
        text = await Promise.race([
          parse,
          new Promise<string>((_, rej) => setTimeout(() => rej(new Error('parse timeout')), 18_000)),
        ])
      } catch { skipped.push(`${d.filename}: read error`); continue }
      if (!text.trim()) { skipped.push(`${d.filename}: scanned/no text layer`); continue }

      // memory: few-shot examples from similar already-verified documents
      // (reuses the doc-search embeddings; empty until a doc is indexed)
      let memory = ''
      try {
        const { data: ex } = await svc.rpc('match_extraction_examples', { p_document_id: d.id, p_count: 2 })
        if (Array.isArray(ex) && ex.length) {
          memory = '\n\nSolved examples from similar documents (previously verified field maps):\n' +
            ex.map((e: Record<string, unknown>) => `- ${e.company_name}: ${JSON.stringify(e.fields)}`).join('\n')
        }
      } catch { /* memory is optional */ }
      const knownBlock = Object.keys(known).length
        ? `\n\nKnown verified data for this customer: ${JSON.stringify(known)} — if the document shows different values, report what the document shows.`
        : ''

      let fields: Record<string, unknown>
      try { fields = await extractFieldsText(o.apiKey, o.model, customerPrompt(o.carrier) + memory + knownBlock + '\n\nDocument text:\n' + sliceText(text)) }
      catch { skipped.push(`${d.filename}: extraction failed`); continue }

      // name-match guard — don't let a mis-filed doc poison this customer
      if (!nameMatches(c.company_name as string, fields.company_name)) { skipped.push(`${d.filename}: broker name mismatch`); continue }
      docsUsed++
      // validate-not-guess: extraction disagreeing with known data is flagged
      // (blanks-only writes make overwrites impossible; this makes them VISIBLE)
      for (const [k, kv] of Object.entries(known)) {
        const got = String(fields[k] ?? '').trim()
        if (got && got.replace(/\W/g, '').toLowerCase() !== kv.replace(/\W/g, '').toLowerCase()) {
          conflicts.push(`${d.filename}: ${k} "${got}" vs known "${kv}"`)
        }
      }
      const candidate: Record<string, unknown> = {
        contact_person: fields.contact_person, phone: fields.phone, email: fields.email,
        billing_address: fields.billing_address, mc_number: fields.mc_number,
        usdot_number: fields.usdot_number, notes: fields.notes || null,
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

    // FMCSA gate: verify any MC/USDOT against FMCSA before writing (fail-closed)
    const vetted = await validateCarrierNumbers(proposed, c.company_name, { webKey: FMCSA_WEBKEY })
    if (vetted.notes.length) conflicts.push(...vetted.notes)
    const proposedFields = vetted.fields as Record<string, string>

    let filled = 0
    if (o.apply && Object.keys(proposedFields).length) {
      const { data: n, error: rpcErr } = await svc.rpc('apply_customer_enrichment', {
        p_customer_id: c.id, p_fields: proposedFields, p_source_document_id: sourceDocId, p_model: o.model,
      })
      if (rpcErr) { report.push({ id: c.id, company_name: c.company_name, error: rpcErr.message }); continue }
      filled = Number(n) || 0
      filledTotal += filled
    }
    report.push({ id: c.id, company_name: c.company_name, docsUsed, filled, proposed: Object.keys(proposed), skipped, conflicts })
    lastId = c.id as number
  }

  return { queried, processed, lastId, filledTotal, customers: report }
}

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()

  const apiKey = Deno.env.get('LLM_API_KEY')
  if (!apiKey) return json({ error: 'No LLM API key configured' }, 400)
  const model = Deno.env.get('LLM_MODEL') ?? 'meta-llama/llama-3.1-8b-instruct'
  const supaUrl = Deno.env.get('SUPABASE_URL')!
  const ref = new URL(supaUrl).hostname.split('.')[0]
  const svc = createClient(supaUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  // ── auth: CRON_SECRET header for jobs, else an admin session ──
  const isCron = requireCron(req)
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  if (!isCron) {
    const caller = await getCaller(req)
    if (caller instanceof Response) return caller
    if (caller.role !== 'admin') return json({ error: 'Not enough permissions' }, 403)
  }

  const { data: settings } = await svc.from('company_settings').select('company_name').eq('id', 1).maybeSingle()
  const carrier = settings?.company_name || 'the carrier'
  // Keep per-invocation work small: edge functions hard-cap at ~150s wall clock,
  // and each doc is a download + LLM call. 2 docs is enough (rate cons carry the
  // full broker contact block).
  const docsPerCustomer = Math.min(Math.max(Number(body.docs_per_customer) || 2, 1), 5)

  // ── probe: counts only, no LLM, no writes (scope + diagnosis) ──
  if (body.probe === true) {
    const c = svc.from('customers')
    const total = (await c.select('id', { count: 'exact', head: true })).count ?? 0
    const anyBlank = (await c.select('id', { count: 'exact', head: true }).or('contact_person.eq.,phone.eq.,email.eq.,billing_address.eq.')).count ?? 0
    const noContact = (await c.select('id', { count: 'exact', head: true }).eq('contact_person', '')).count ?? 0
    const noPhone = (await c.select('id', { count: 'exact', head: true }).eq('phone', '')).count ?? 0
    const noEmail = (await c.select('id', { count: 'exact', head: true }).eq('email', '')).count ?? 0
    const noBilling = (await c.select('id', { count: 'exact', head: true }).eq('billing_address', '')).count ?? 0
    const enriched = (await c.select('id', { count: 'exact', head: true }).not('enriched_at', 'is', null)).count ?? 0
    const custDocs = (await svc.from('documents').select('id', { count: 'exact', head: true }).eq('entity_type', 'customer')).count ?? 0
    const loadDocs = (await svc.from('documents').select('id', { count: 'exact', head: true }).eq('entity_type', 'load')).count ?? 0
    return json({ probe: true, total, anyBlank, noContact, noPhone, noEmail, noBilling, enriched, customerDocs: custDocs, loadDocs })
  }

  // ── pod_report: missing-POD detector output (cron/admin read) ──
  if (body.mode === 'pod_report') {
    const days = Number(body.days) || 45
    const { data: rows, error: rErr } = await svc.rpc('loads_missing_pod', { p_days: days })
    const list = (rows ?? []) as Array<Record<string, string>>
    // annotate only the shown rows with an archive candidate (bounded lookups)
    const shown = list.slice(0, 40)
    for (const r of shown) {
      const { data: cand } = await svc.rpc('pod_archive_candidate', { p_ref: r.reference_number ?? '', p_pickup: r.pickup_number ?? '', p_delivery: r.delivery_number ?? '' })
      r.archive_file = (cand as string) ?? null as unknown as string
    }
    const inArchive = shown.filter((r) => r.archive_file).length
    return json({ summary: { missing: list.length, shown: shown.length, in_archive_sampled: inArchive, days }, rows: shown, errors: [rErr?.message].filter(Boolean) })
  }

  // ── migration_refs: name lists for the ITS import dry-run (cron/admin read) ──
  if (body.mode === 'migration_refs') {
    const custs = (await svc.from('customers').select('company_name, mc_number, usdot_number')).data ?? []
    const drivers = (await svc.from('drivers').select('full_name')).data ?? []
    const trucks = (await svc.from('trucks').select('unit_number')).data ?? []
    const loadNotes = (await svc.from('loads').select('load_number, notes')).data ?? []
    // recent invoices (last 45 days) — to check gap-load revenue is captured
    const since = new Date(Date.now() - 45 * 864e5).toISOString().slice(0, 10)
    const inv = (await svc.from('invoices')
      .select('invoice_number, total, invoice_date, source, load_id, qbo_doc_number, customer:customers(company_name)')
      .gte('invoice_date', since).order('invoice_date', { ascending: false })).data ?? []
    return json({
      customers: custs.map((c) => c.company_name),
      customer_ids: custs.map((c) => ({ name: c.company_name, mc: c.mc_number, dot: c.usdot_number })),
      drivers: drivers.map((d) => d.full_name),
      trucks: trucks.map((t) => t.unit_number),
      existing_loads: loadNotes.map((l) => ({ n: l.load_number, its: /\[ITS #(\d+)\]/.exec(l.notes ?? '')?.[1] ?? null })),
      recent_invoices: inv.map((i) => ({
        num: i.invoice_number, total: i.total, date: i.invoice_date, source: i.source,
        load_id: i.load_id, qbo: i.qbo_doc_number,
        customer: (i.customer as { company_name?: string } | null)?.company_name ?? null,
      })),
    })
  }

  // ── apply pre-extracted fields (client-side vision of a rate con) ──
  // The browser renders a scanned rate-con to images and reads it with the
  // vision model (extract-pdf), then posts the fields here; we apply blanks-only.
  if (body.customer_id && body.fields && typeof body.fields === 'object') {
    const f = body.fields as Record<string, unknown>
    const fields: Record<string, unknown> = {
      contact_person: f.contact_person, phone: f.phone, email: f.email,
      billing_address: f.billing_address, mc_number: f.mc_number, usdot_number: f.usdot_number, notes: f.notes || null,
    }
    // memory: flag disagreements with known-verified data (blanks-only writes
    // already make overwrites impossible — this makes disagreements VISIBLE)
    const conflicts: string[] = []
    const { data: cur } = await svc.from('customers')
      .select('company_name, contact_person, phone, email, billing_address, mc_number, usdot_number')
      .eq('id', Number(body.customer_id)).maybeSingle()
    for (const [k, kv] of Object.entries(cur ?? {})) {
      const knownVal = String(kv ?? '').trim()
      const got = String(fields[k] ?? '').trim()
      if (knownVal && got && got.replace(/\W/g, '').toLowerCase() !== knownVal.replace(/\W/g, '').toLowerCase()) {
        conflicts.push(`${k}: "${got}" vs known "${knownVal}"`)
      }
    }
    // FMCSA gate: verify any MC/USDOT against FMCSA before writing (fail-closed)
    const vetted = await validateCarrierNumbers(fields, cur?.company_name ?? null, { webKey: FMCSA_WEBKEY })
    if (vetted.notes.length) conflicts.push(...vetted.notes)
    const { data: n, error: rpcErr } = await svc.rpc('apply_customer_enrichment', {
      p_customer_id: Number(body.customer_id), p_fields: vetted.fields, p_source_document_id: body.source_document_id ?? null, p_model: 'vision:ratecon',
    })
    if (rpcErr) return json({ error: rpcErr.message }, 500)
    return json({ filled: Number(n) || 0, conflicts })
  }

  // ── dupes_report: duplicate-customer groups (normalized-name key) ──
  if (body.mode === 'dupes_report') {
    const { data, error } = await svc.rpc('duplicate_customer_groups')
    if (error) return json({ error: error.message }, 500)
    return json({ groups: data ?? [] })
  }

  // ── merge_auto: merge duplicate groups; the server decides every pair ──
  // Callers can only say "go" (or dry_run) — which merges happen is computed
  // here: keeper = most loads/invoices/oldest (the report's member order); a
  // pair is SKIPPED when both sides carry MC numbers that differ (same name,
  // different company).
  if (body.mode === 'merge_auto') {
    const dry = !!body.dry_run
    const { data: groups, error } = await svc.rpc('duplicate_customer_groups')
    if (error) return json({ error: error.message }, 500)
    type Member = { id: number; company_name: string; mc_number: string; usdot_number: string; qbo_id: string | null; loads: number; invoices: number }
    const results: Array<Record<string, unknown>> = []
    let merged = 0, skipped = 0
    const digits = (s: string | null | undefined) => (s ?? '').replace(/\D/g, '')
    for (const g of (groups ?? []) as Array<{ norm_key: string; members: Member[] }>) {
      const keeper = g.members[0]
      for (const dupe of g.members.slice(1)) {
        // MC / USDOT are each unique per company — when both sides carry the
        // same kind of number and it differs, these are different companies.
        const mcA = digits(keeper.mc_number), mcB = digits(dupe.mc_number)
        const dotA = digits(keeper.usdot_number), dotB = digits(dupe.usdot_number)
        if (mcA && mcB && mcA !== mcB) {
          skipped++
          results.push({ group: g.norm_key, skipped: dupe.company_name, reason: `MC mismatch (${mcA} vs ${mcB})` })
          continue
        }
        if (dotA && dotB && dotA !== dotB) {
          skipped++
          results.push({ group: g.norm_key, skipped: dupe.company_name, reason: `USDOT mismatch (${dotA} vs ${dotB})` })
          continue
        }
        if (dry) {
          results.push({ group: g.norm_key, would_merge: `${dupe.company_name} (#${dupe.id})`, into: `${keeper.company_name} (#${keeper.id})`, dupe_loads: dupe.loads, dupe_invoices: dupe.invoices })
          continue
        }
        const { data: res, error: mErr } = await svc.rpc('merge_customers', { p_keep: keeper.id, p_dupe: dupe.id })
        if (mErr) { results.push({ group: g.norm_key, dupe: dupe.id, error: mErr.message }); skipped++ }
        else { merged++; results.push(res as Record<string, unknown>) }
      }
    }
    return json({ groups: (groups ?? []).length, merged, skipped, dry_run: dry, results })
  }

  // ── llm_diag: report the configured LLM endpoint + its model list (no key) ──
  if (body.mode === 'llm_diag') {
    const base = Deno.env.get('LLM_BASE_URL') ?? 'https://openrouter.ai/api/v1'
    let models: string[] = []
    try {
      const r = await fetch(`${base}/models`, { headers: { Authorization: `Bearer ${apiKey}` } })
      const j = await r.json()
      // deno-lint-ignore no-explicit-any
      models = ((j?.data ?? j?.models ?? []) as any[]).map((m) => String(m.id ?? m.name ?? '')).filter(Boolean)
    } catch { /* ignore */ }
    return json({
      base_host: (() => { try { return new URL(base).host } catch { return base } })(),
      text_model: Deno.env.get('LLM_MODEL') ?? '(default)',
      vision_model: Deno.env.get('LLM_VISION_MODEL') ?? '(default)',
      vision_candidates: models.filter((m) => /vision|scout|maverick|llava|vl|4o|gemini|pixtral/i.test(m)),
      all_models: models,
    })
  }

  // ── vision pipeline (NAS rasterizes, edge holds the secrets) ──
  // vision_targets: hand out customers still missing contact info + a signed URL
  // to one of their loads' rate cons. The NAS downloads + rasterizes, then posts
  // the page images to vision_apply. Bypasses extract-pdf's per-user rate limit.
  if (body.mode === 'vision_targets') {
    const afterId = Number(body.after_id) || 0
    const limit = Math.min(Math.max(Number(body.limit) || 8, 1), 25)
    const { data: custs } = await svc.from('customers').select('id, company_name')
      .or('contact_person.eq.,phone.eq.,email.eq.').gt('id', afterId).order('id', { ascending: true }).limit(limit)
    const targets: Array<Record<string, unknown>> = []
    let lastId = afterId
    for (const c of custs ?? []) {
      lastId = c.id as number
      const { data: loads } = await svc.from('loads').select('id').eq('customer_id', c.id).limit(80)
      const loadIds = (loads ?? []).map((l) => l.id)
      if (!loadIds.length) continue
      const { data: docs } = await svc.from('documents').select('id, storage_path, filename, content_type')
        .eq('entity_type', 'load').in('entity_id', loadIds).order('uploaded_at', { ascending: false }).limit(4)
      const pdf = (docs ?? []).find((d) => /pdf/i.test(d.content_type) || /\.pdf$/i.test(d.filename))
      if (!pdf) continue
      const { data: signed } = await svc.storage.from('documents').createSignedUrl(pdf.storage_path, 900)
      if (!signed?.signedUrl) continue
      targets.push({ customer_id: c.id, company_name: c.company_name, doc_id: pdf.id, url: signed.signedUrl })
    }
    return json({ targets, lastId, queried: (custs ?? []).length })
  }

  // vision_apply: run the cloud vision model on the rasterized rate-con pages and
  // fill blanks. Name-match guard so a mis-filed doc can't poison this customer.
  if (body.mode === 'vision_apply') {
    const images = (body.images as string[]) || []
    if (!body.customer_id || !images.length) return json({ error: 'need customer_id + images' }, 400)
    // Vision can use its own provider (text stays on the main one, e.g. Groq,
    // which has no vision model). Falls back to the main key/base if unset.
    const visionKey = Deno.env.get('LLM_VISION_KEY') || apiKey
    const visionBase = Deno.env.get('LLM_VISION_BASE_URL') || undefined
    const visionModel = Deno.env.get('LLM_VISION_MODEL') ?? 'gpt-4o-mini'
    // deno-lint-ignore no-explicit-any
    const parts: any = [{ type: 'text', text: customerPrompt(carrier) + '\n\nThe rate confirmation pages follow as images.' }]
    for (const img of images.slice(0, 4)) parts.push({ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${img}` } })
    let f: Record<string, unknown>
    try { f = await extractFields(visionKey, visionModel, parts, visionBase) } catch (e) { return json({ error: String(e).slice(0, 200) }, 502) }
    if (body.company_name && f.company_name) {
      const a = norm(String(body.company_name)), b = norm(String(f.company_name))
      let hit = false
      for (const t of b) if (a.has(t)) hit = true
      if (!hit) return json({ filled: 0, skipped: 'name mismatch' })
    }
    const mc = f.mc_number ? `MC# ${String(f.mc_number).trim()}` : ''
    const noteVal = [mc, f.notes ? String(f.notes).trim() : ''].filter(Boolean).join(' — ')
    const fields: Record<string, unknown> = {
      contact_person: f.contact_person, phone: f.phone, email: f.email, billing_address: f.billing_address, notes: noteVal || null,
    }
    const { data: n, error } = await svc.rpc('apply_customer_enrichment', {
      p_customer_id: Number(body.customer_id), p_fields: fields, p_source_document_id: body.doc_id ?? null, p_model: 'vision:ratecon:nas',
    })
    if (error) return json({ error: error.message }, 500)
    return json({ filled: Number(n) || 0 })
  }

  // ── cron / anon: maintenance sweep (apply, loop under a time budget) ──
  // Honours optional limit / max_batches so a first run can be kept small and
  // watched; returns the customers it actually filled for observability.
  if (isCron || body.cron === true) {
    const started = Date.now()
    const deadline = started + 100_000 // return well under the platform's 150s ceiling
    const maxBatches = Math.min(Math.max(Number(body.max_batches) || 4, 1), 40)
    const perBatch = Math.min(Math.max(Number(body.limit) || 6, 1), 50)
    let afterId = Number(body.after_id) || 0
    let scanned = 0, processed = 0, filledTotal = 0, touched = 0, batches = 0
    const filledCustomers: Array<Record<string, unknown>> = []
    for (let i = 0; i < maxBatches; i++) {
      const r = await runBatch(svc, { afterId, limit: perBatch, docsPerCustomer, apply: true, oneCustomer: null, apiKey, model, carrier, deadlineMs: deadline })
      batches++
      scanned += r.queried
      processed += r.processed
      filledTotal += r.filledTotal
      for (const c of r.customers as Array<Record<string, unknown>>) {
        if (Number(c.filled) > 0) { touched++; if (filledCustomers.length < 60) filledCustomers.push({ id: c.id, company_name: c.company_name, filled: c.filled, fields: c.proposed }) }
      }
      if (r.queried === 0 || r.lastId <= afterId) break // no more candidates, or deadline hit
      afterId = r.lastId
      if (Date.now() > deadline) break
    }
    return json({ mode: 'cron', scanned, processed, filledTotal, touched, batches, lastId: afterId, filledCustomers })
  }

  // ── admin: one cursor-paged batch (the UI loops) ──
  const r = await runBatch(svc, {
    afterId: Number(body.after_id) || 0,
    limit: Math.min(Math.max(Number(body.limit) || 6, 1), 50),
    docsPerCustomer,
    apply: body.apply === true,
    oneCustomer: body.customer_id ? Number(body.customer_id) : null,
    apiKey, model, carrier,
    deadlineMs: Date.now() + 110_000,
  })
  return json({ apply: body.apply === true, ...r })
}))

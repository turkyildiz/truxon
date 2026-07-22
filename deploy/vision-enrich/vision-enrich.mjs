#!/usr/bin/env node
// NAS vision enrichment (LOCAL) — fills blank customer contact fields by reading
// each customer's SCANNED rate confirmations with a LOCAL vision model (Ollama)
// on the NAS CPU. No external LLM key, no cloud, fully private.
//
// Flow per customer:
//   edge vision_targets  → { customer_id, company_name, doc_id, signed url }
//   fetch the PDF (signed url) → pdftoppm → JPEG pages
//   LOCAL Ollama (vision) → JSON contact fields
//   NAS name-match guard → edge apply_fields → blanks-only write
//
// The edge holds the DB secrets; this box runs the model locally. Slow on CPU —
// meant as an overnight backfill.
//
// Env (deploy/vision-enrich/vision.env, chmod 600):
//   CUSTOMER_ENRICH_URL   https://<ref>.supabase.co/functions/v1/customer-enrich
//   SUPABASE_ANON_JWT     public JWT-format anon token
//   OLLAMA_URL            default http://127.0.0.1:11434
//   OLLAMA_MODEL          default minicpm-v
//   CARRIER               our carrier name (default "Aida Logistics LLC")
//   MAX_CUSTOMERS / RASTER_DPI / MAX_PAGES

import { readFileSync, writeFileSync, mkdtempSync, readdirSync, rmSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const env = loadEnv(join(HERE, 'vision.env'))
const URL = env.CUSTOMER_ENRICH_URL
const JWT = env.SUPABASE_ANON_JWT
// customer-enrich is admin/cron-gated; the anon JWT alone is rejected (401), so
// we authenticate the job with the CRON_SECRET via the x-cron-key header.
const CRON = env.CRON_SECRET || ''
const OLLAMA = (env.OLLAMA_URL || 'http://127.0.0.1:11434').replace(/\/$/, '')
const MODEL = env.OLLAMA_MODEL || 'minicpm-v'
const CARRIER = env.CARRIER || 'Aida Logistics LLC'
const MAX_CUSTOMERS = Number(env.MAX_CUSTOMERS || 1000)
const DPI = Number(env.RASTER_DPI || 130)
const PAGES = Number(env.MAX_PAGES || 2)

const STOP = new Set(['inc', 'llc', 'ltd', 'co', 'corp', 'company', 'group', 'the', 'and', 'of', 'logistics', 'transport', 'transportation', 'freight', 'trucking', 'carriers', 'carrier', 'services', 'service', 'brokerage', 'solutions', 'usa', 'dba'])
const toks = (s) => new Set(String(s ?? '').toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter((t) => t.length > 2 && !STOP.has(t)))

function loadEnv(p) {
  try {
    return Object.fromEntries(readFileSync(p, 'utf8').split('\n')
      .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  } catch { return {} }
}
const log = (m) => console.log(`[vision] ${new Date().toISOString()} ${m}`)

// Name-specific prompt: we already know which broker this rate con belongs to,
// so we tell the model exactly whose details to pull — no carrier/broker guessing.
const buildPrompt = (broker) => `You are reading a scanned trucking RATE CONFIRMATION. Find the contact details for the FREIGHT BROKER named "${broker}". Look across the whole page (letterhead, header, "Broker" block, footer) for THEIR phone, email, mailing/billing address, MC number, USDOT number, and a contact person (their rep/dispatcher).
Respond with ONLY a JSON object, null for anything not shown:
{"company_name": the broker name you found, "contact_person": ..., "phone": ..., "email": ..., "billing_address": ..., "mc_number": ..., "usdot_number": ..., "notes": short billing note or null}
IMPORTANT: return the BROKER "${broker}"'s details, NOT "${CARRIER}" — that is the trucking carrier being hired, ignore its contact info.`

async function edge(body) {
  const r = await fetch(URL, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${JWT}`, 'x-cron-key': CRON }, body: JSON.stringify(body) })
  return r.json()
}

async function ollamaVision(images, prompt) {
  const r = await fetch(`${OLLAMA}/api/chat`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: MODEL,
      messages: [{ role: 'user', content: prompt, images }],
      format: 'json',
      stream: false,
      // Keep Ollama's default 4096-token window: on the 8 GB card a larger num_ctx
      // OOMs the vision model's KV cache. RASTER_DPI is tuned (≈150) so a page
      // image stays under that window. FMCSA verification backstops number reads.
      options: { temperature: 0 },
    }),
    signal: AbortSignal.timeout(600_000), // GPU is fast, but keep a generous ceiling
  })
  if (!r.ok) throw new Error(`ollama ${r.status}: ${(await r.text()).slice(0, 120)}`)
  const j = await r.json()
  const content = j?.message?.content ?? ''
  try { return JSON.parse(content) } catch { return JSON.parse((content.match(/\{[\s\S]*\}/) || ['{}'])[0]) }
}

async function main() {
  if (!URL || !CRON) throw new Error('CUSTOMER_ENRICH_URL and CRON_SECRET required in vision.env')
  log(`model=${MODEL} ollama=${OLLAMA}`)
  let after = 0, done = 0, filled = 0, touched = 0
  while (done < MAX_CUSTOMERS) {
    const { targets, lastId, queried } = await edge({ mode: 'vision_targets', after_id: after, limit: 8 })
    if (!queried) { log('no more candidates'); break }
    for (const t of targets ?? []) {
      if (done >= MAX_CUSTOMERS) break
      done++
      let dir
      try {
        const pdf = Buffer.from(await (await fetch(t.url)).arrayBuffer())
        dir = mkdtempSync(join(tmpdir(), 'rc-'))
        writeFileSync(join(dir, 'in.pdf'), pdf)
        // Many rate cons are owner-password encrypted — poppler refuses those.
        // Strip encryption first with qpdf (harmless if not encrypted).
        let src = join(dir, 'in.pdf')
        try { execFileSync('qpdf', ['--decrypt', src, join(dir, 'dec.pdf')], { stdio: 'ignore' }); src = join(dir, 'dec.pdf') } catch { /* not encrypted / qpdf absent */ }
        try {
          execFileSync('pdftoppm', ['-jpeg', '-r', String(DPI), '-f', '1', '-l', String(PAGES), src, join(dir, 'p')], { stdio: 'ignore' })
        } catch {
          // last resort: pdftocairo handles some PDFs poppler's pdftoppm chokes on
          execFileSync('pdftocairo', ['-jpeg', '-r', String(DPI), '-f', '1', '-l', String(PAGES), src, join(dir, 'p')], { stdio: 'ignore' })
        }
        const imgs = readdirSync(dir).filter((f) => f.endsWith('.jpg')).sort().slice(0, PAGES).map((f) => readFileSync(join(dir, f)).toString('base64'))
        if (!imgs.length) { log(`0  ${t.company_name} (no pages)`); continue }
        const f = await ollamaVision(imgs, buildPrompt(t.company_name))
        // guard: reject only if the model clearly returned OUR carrier's block
        // instead of the broker's (the observed failure mode)
        if (f.company_name) {
          const got = toks(f.company_name), want = toks(t.company_name), carrier = toks(CARRIER)
          const looksCarrier = [...got].some((x) => carrier.has(x)) && ![...got].some((x) => want.has(x))
          if (looksCarrier) { log(`0  ${t.company_name} (got carrier, not broker)`); continue }
        }
        const res = await edge({ customer_id: t.customer_id, source_document_id: t.doc_id, fields: { contact_person: f.contact_person, phone: f.phone, email: f.email, billing_address: f.billing_address, mc_number: f.mc_number, usdot_number: f.usdot_number, notes: f.notes } })
        const n = Number(res.filled) || 0
        if (Array.isArray(res.conflicts) && res.conflicts.length) log(`⚠ ${t.company_name} conflicts: ${res.conflicts.join('; ')}`)
        if (n > 0) { filled += n; touched++; log(`+${n} ${t.company_name}`) }
        else log(`0  ${t.company_name}${res.error ? ` [${res.error}]` : ''}`)
      } catch (e) {
        log(`${t.company_name}: ${String(e).slice(0, 100)}`)
      } finally {
        if (dir) rmSync(dir, { recursive: true, force: true })
      }
    }
    if (lastId <= after) break
    after = lastId
  }
  log(`DONE: processed ${done}, filled ${filled} field(s) on ${touched} customer(s)`)
}

main().catch((e) => { console.error(`[vision] ERROR: ${e.message}`); process.exit(1) })

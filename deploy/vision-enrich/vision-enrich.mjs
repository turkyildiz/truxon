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
// Tiling (R9 #2): whole pages are capped at 150 DPI because the vision
// ENCODER's activations OOM the 8 GB card at 200. Overlapping half-page tiles
// at TILE_DPI each carry roughly a full 150-DPI page's pixel budget, so the
// model reads small print (reference #s, fine-print accessorials) without
// touching the VRAM ceiling. VISION_TILING=0 reverts to whole-page.
const TILING = env.VISION_TILING !== '0'
const TILE_DPI = Number(env.TILE_DPI || 200)  // halves at 200 ≈ 2.06M px, just under the 150-DPI-full-page budget the encoder is proven to survive

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
      // 8k context fits on the 8 GB card since Lynx runs Ollama with flash-attention
      // + q8_0 KV-cache quantization (see deploy/gpu-box) — gives multi-page headroom
      // without overflowing the window. RASTER_DPI stays 150: at 200 the vision
      // ENCODER activations (not the KV cache) OOM the card. FMCSA backstops numbers.
      options: { temperature: 0, num_ctx: 8192 },
    }),
    signal: AbortSignal.timeout(600_000), // GPU is fast, but keep a generous ceiling
  })
  if (!r.ok) throw new Error(`ollama ${r.status}: ${(await r.text()).slice(0, 120)}`)
  const j = await r.json()
  const content = j?.message?.content ?? ''
  try { return JSON.parse(content) } catch { return JSON.parse((content.match(/\{[\s\S]*\}/) || ['{}'])[0]) }
}

/** Page size in px at a DPI, via pdfinfo (points × dpi / 72). */
function pageSizePx(src, dpi) {
  const out = execFileSync('pdfinfo', [src]).toString()
  const m = out.match(/Page size:\s+([\d.]+) x ([\d.]+)/)
  if (!m) return null
  return { w: Math.round((Number(m[1]) * dpi) / 72), h: Math.round((Number(m[2]) * dpi) / 72) }
}

/** Render page 1..pages as overlapping half-page tiles at TILE_DPI. */
function rasterTiles(src, dir, pages) {
  const size = pageSizePx(src, TILE_DPI)
  if (!size) return []
  const half = Math.round(size.h * 0.55)          // 55% + 55% = 10% overlap
  const yBottom = size.h - half
  const tiles = []
  for (let p = 1; p <= pages; p++) {
    for (const [tag, y] of [['top', 0], ['bot', yBottom]]) {
      const prefix = join(dir, `t${p}${tag}`)
      execFileSync('pdftoppm', ['-jpeg', '-r', String(TILE_DPI), '-f', String(p), '-l', String(p),
        '-x', '0', '-y', String(y), '-W', String(size.w), '-H', String(half), src, prefix], { stdio: 'ignore' })
      const f = readdirSync(dir).find((n) => n.startsWith(`t${p}${tag}`) && n.endsWith('.jpg'))
      if (f) tiles.push(readFileSync(join(dir, f)).toString('base64'))
    }
  }
  return tiles
}

/** Merge per-tile extractions: first non-null wins, longest address wins. */
function mergeFields(results) {
  const out = {}
  for (const r of results) {
    if (!r) continue
    for (const [k, v] of Object.entries(r)) {
      if (v == null || v === '') continue
      if (k === 'billing_address' && out[k] && String(v).length <= String(out[k]).length) continue
      if (out[k] == null || k === 'billing_address') out[k] = v
    }
  }
  return out
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
        const imgs = readdirSync(dir).filter((f) => f.endsWith('.jpg') && !f.startsWith('t')).sort().slice(0, PAGES).map((f) => readFileSync(join(dir, f)).toString('base64'))
        if (!imgs.length) { log(`0  ${t.company_name} (no pages)`); continue }
        let f
        if (TILING) {
          // High-DPI overlapping half-page tiles, one model call per tile,
          // merged first-non-null. Falls back to the whole-page read when
          // tiling renders nothing or finds nothing.
          let tiles = []
          try { tiles = rasterTiles(src, dir, PAGES) } catch { /* pdfinfo/crop failed */ }
          if (tiles.length) {
            const parts = []
            for (const tile of tiles) {
              try { parts.push(await ollamaVision([tile], buildPrompt(t.company_name))) }
              catch (e) { log(`  tile err: ${String(e).slice(0, 60)}`) }
            }
            f = mergeFields(parts)
          }
          if (!f || Object.keys(f).length === 0) f = await ollamaVision(imgs, buildPrompt(t.company_name))
        } else {
          f = await ollamaVision(imgs, buildPrompt(t.company_name))
        }
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

#!/usr/bin/env node
// NAS vision enrichment — fills blank customer contact fields by reading each
// customer's SCANNED rate confirmations with cloud vision AI. The NAS only
// rasterizes (poppler/pdftoppm); the customer-enrich edge function holds every
// secret (storage access, the LLM key, the DB write). So this box carries NO
// sensitive credentials — just the PUBLIC anon token + poppler.
//
// Flow per customer:
//   edge vision_targets  → { customer_id, company_name, doc_id, signed url }
//   fetch the PDF (signed url) → pdftoppm → JPEG pages
//   edge vision_apply    → runs the vision model + fills blanks-only
//
// No extract-pdf 30/hr cap (the vision_* path is cron-gated, not per-user).
//
// Env (deploy/vision-enrich/vision.env, chmod 600):
//   CUSTOMER_ENRICH_URL   https://<ref>.supabase.co/functions/v1/customer-enrich
//   SUPABASE_ANON_JWT     the public JWT-format anon token (cron identity)
//   MAX_CUSTOMERS         safety cap per run (default 1000)
//   RASTER_DPI            pdftoppm resolution (default 130)
//   MAX_PAGES             pages per rate con to read (default 2)

import { readFileSync, writeFileSync, mkdtempSync, readdirSync, rmSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const env = loadEnv(join(HERE, 'vision.env'))
const URL = env.CUSTOMER_ENRICH_URL
const JWT = env.SUPABASE_ANON_JWT
const MAX_CUSTOMERS = Number(env.MAX_CUSTOMERS || 1000)
const DPI = Number(env.RASTER_DPI || 130)
const PAGES = Number(env.MAX_PAGES || 2)

function loadEnv(p) {
  try {
    return Object.fromEntries(readFileSync(p, 'utf8').split('\n')
      .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  } catch { return {} }
}
const log = (m) => console.log(`[vision] ${new Date().toISOString()} ${m}`)

async function post(body) {
  const r = await fetch(URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${JWT}` },
    body: JSON.stringify(body),
  })
  return r.json()
}

async function main() {
  if (!URL || !JWT) throw new Error('CUSTOMER_ENRICH_URL and SUPABASE_ANON_JWT required in vision.env')
  let after = 0, done = 0, filled = 0, touched = 0
  while (done < MAX_CUSTOMERS) {
    const { targets, lastId, queried } = await post({ mode: 'vision_targets', after_id: after, limit: 8 })
    if (!queried) { log('no more candidates'); break }
    for (const t of targets ?? []) {
      if (done >= MAX_CUSTOMERS) break
      done++
      let dir
      try {
        const pdf = Buffer.from(await (await fetch(t.url)).arrayBuffer())
        dir = mkdtempSync(join(tmpdir(), 'rc-'))
        const pdfPath = join(dir, 'in.pdf')
        writeFileSync(pdfPath, pdf)
        execFileSync('pdftoppm', ['-jpeg', '-r', String(DPI), '-f', '1', '-l', String(PAGES), pdfPath, join(dir, 'p')], { stdio: 'ignore' })
        const imgs = readdirSync(dir).filter((f) => f.endsWith('.jpg')).sort().slice(0, PAGES)
          .map((f) => readFileSync(join(dir, f)).toString('base64'))
        if (!imgs.length) { log(`0  ${t.company_name} (no pages)`); continue }
        const res = await post({ mode: 'vision_apply', customer_id: t.customer_id, company_name: t.company_name, doc_id: t.doc_id, images: imgs })
        const f = Number(res.filled) || 0
        if (f > 0) { filled += f; touched++; log(`+${f} ${t.company_name}`) }
        else log(`0  ${t.company_name}${res.skipped ? ` (${res.skipped})` : ''}${res.error ? ` [${res.error}]` : ''}`)
      } catch (e) {
        log(`${t.company_name}: ${String(e).slice(0, 90)}`)
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

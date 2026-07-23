#!/usr/bin/env node
// NAS doc classifier (R9 #101) — asks the local qwen2.5:3b to pick a canonical
// doc type for each 'Other' document whose indexed text exists. Strict label
// set, temperature 0, exact-match acceptance only; anything the model can't
// place with confidence stays 'Other'. The edge validates the label again.
// Env: deploy/doc-rag/rag.env (same file as the indexer).

import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const env = loadEnv(join(HERE, 'rag.env'))
const URL = env.DOC_RAG_URL
const JWT = env.SUPABASE_ANON_JWT
const CRON = env.CRON_SECRET || ''
// classify runs on the NAS-LOCAL 3B by design (bulk work stays free/private);
// rag.env's OLLAMA_URL points at Lynx for embeddings, so use a dedicated var.
const OLLAMA = (env.CLASSIFY_OLLAMA_URL || 'http://127.0.0.1:11434').replace(/\/$/, '')
const MODEL = env.CLASSIFY_MODEL || 'qwen2.5:3b-t8'

const LABELS = ['POD', 'Rate Confirmation', 'BOL', 'Invoice', 'Registration', 'Insurance',
  'Inspection', 'License', 'Medical Card', 'Receipt', 'Employment']

function loadEnv(p) {
  try {
    return Object.fromEntries(readFileSync(p, 'utf8').split('\n')
      .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  } catch { return {} }
}
const log = (m) => console.log(`[classify] ${new Date().toISOString()} ${m}`)

async function edge(body) {
  const r = await fetch(URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${JWT}`, ...(CRON ? { 'x-cron-key': CRON } : {}) },
    body: JSON.stringify(body),
  })
  return r.json()
}

async function ask(filename, excerpt) {
  const prompt = `You label trucking-company documents. Pick EXACTLY ONE label from this list, or "Other" if unsure:
${LABELS.join(' | ')} | Other

POD = signed proof of delivery. Rate Confirmation = broker rate/load confirmation. BOL = bill of lading. Receipt = fuel/repair/purchase receipt.

Filename: ${filename}
Document text:
"""${excerpt}"""

Answer with the label only, nothing else.`
  const r = await fetch(`${OLLAMA}/api/generate`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: MODEL, prompt, stream: false, options: { temperature: 0, num_predict: 10 } }),
    signal: AbortSignal.timeout(90_000),
  })
  if (!r.ok) throw new Error(`ollama ${r.status}`)
  return String((await r.json()).response ?? '').trim().replace(/^["']|["'.]$/g, '')
}

const stats = { seen: 0, applied: 0, kept_other: 0, errors: 0 }
for (let round = 0; round < 10; round++) {
  const { targets } = await edge({ mode: 'classify_targets', limit: 20 })
  if (!targets?.length) break
  let progressed = false
  for (const t of targets) {
    stats.seen++
    try {
      const t0 = Date.now()
      const raw = await ask(t.filename, t.excerpt)
      const label = LABELS.find((l) => raw.toLowerCase() === l.toLowerCase())
      if (!label) { stats.kept_other++; continue }
      const res = await edge({ mode: 'classify_apply', document_id: t.document_id, doc_type: label, model: MODEL, latency_ms: Date.now() - t0 })
      if (res.ok) { stats.applied++; progressed = true; log(`#${t.document_id} ${t.filename} -> ${label}`) }
      else stats.errors++
    } catch (e) {
      stats.errors++
      log(`#${t.document_id} error: ${e.message}`)
    }
  }
  // docs the model kept as 'Other' would repeat forever — stop when a full
  // round applies nothing
  if (!progressed) break
}
log(`done: ${JSON.stringify(stats)}`)

#!/usr/bin/env node
// NAS search worker — the query half of document RAG. Polls Truxon for queued
// searches, embeds each query with the SAME local model as the documents
// (nomic-embed-text), and hands the vector back; the edge function runs the
// cosine match and stores results. Runs continuously (systemd/pm2/nohup).
//
// Env (deploy/doc-rag/rag.env, chmod 600) — same file as the indexer:
//   DOC_RAG_URL         https://<ref>.supabase.co/functions/v1/doc-rag
//   SUPABASE_ANON_JWT   public JWT-format anon token
//   OLLAMA_URL          default http://127.0.0.1:11434
//   EMBED_MODEL         default nomic-embed-text
//   POLL_MS             idle poll interval, default 2000

import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const env = loadEnv(join(HERE, 'rag.env'))
const URL = env.DOC_RAG_URL
const JWT = env.SUPABASE_ANON_JWT
const OLLAMA = (env.OLLAMA_URL || 'http://127.0.0.1:11434').replace(/\/$/, '')
const EMBED_MODEL = env.EMBED_MODEL || 'nomic-embed-text'
const POLL_MS = Number(env.POLL_MS || 2000)

function loadEnv(p) {
  try {
    return Object.fromEntries(readFileSync(p, 'utf8').split('\n')
      .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  } catch { return {} }
}
const log = (m) => console.log(`[search] ${new Date().toISOString()} ${m}`)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function edge(body) {
  const r = await fetch(URL, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${JWT}` }, body: JSON.stringify(body) })
  return r.json()
}
async function embed(text) {
  const r = await fetch(`${OLLAMA}/api/embeddings`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: EMBED_MODEL, prompt: text }), signal: AbortSignal.timeout(60_000),
  })
  if (!r.ok) throw new Error(`ollama ${r.status}`)
  return (await r.json()).embedding
}

async function main() {
  if (!URL || !JWT) throw new Error('DOC_RAG_URL and SUPABASE_ANON_JWT required in rag.env')
  log(`up — model=${EMBED_MODEL} poll=${POLL_MS}ms`)
  for (;;) {
    let req
    try {
      ({ request: req } = await edge({ mode: 'search_targets' }))
    } catch (e) {
      log(`poll error: ${String(e).slice(0, 80)}`); await sleep(POLL_MS * 3); continue
    }
    if (!req) { await sleep(POLL_MS); continue }
    const t0 = Date.now()
    try {
      const vec = await embed(req.query)
      const res = await edge({ mode: 'search_complete', request_id: req.id, query_embedding: vec })
      log(`#${req.id} "${String(req.query).slice(0, 48)}" → ${res.stored ?? res.error ?? '?'} (${Date.now() - t0}ms)`)
    } catch (e) {
      await edge({ mode: 'search_complete', request_id: req.id, worker_error: String(e).slice(0, 120) })
      log(`#${req.id} failed: ${String(e).slice(0, 80)}`)
    }
  }
}
main().catch((e) => { console.error(`[search] FATAL: ${e.message}`); process.exit(1) })

#!/usr/bin/env node
// NAS document indexer — extracts each document's text (poppler, qpdf-decrypt for
// encrypted PDFs), chunks it, embeds locally with nomic-embed-text (Ollama), and
// stores the vectors in Truxon's pgvector via the doc-rag edge function. Free +
// private; the NAS holds no DB secrets (edge does storage + the write).
//
// Env (deploy/doc-rag/rag.env, chmod 600):
//   DOC_RAG_URL         https://<ref>.supabase.co/functions/v1/doc-rag
//   SUPABASE_ANON_JWT   public JWT-format anon token
//   OLLAMA_URL          default http://127.0.0.1:11434
//   EMBED_MODEL         default nomic-embed-text
//   MAX_DOCS            per-run cap (default 100000)

import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const env = loadEnv(join(HERE, 'rag.env'))
const URL = env.DOC_RAG_URL
const JWT = env.SUPABASE_ANON_JWT
const OLLAMA = (env.OLLAMA_URL || 'http://127.0.0.1:11434').replace(/\/$/, '')
const EMBED_MODEL = env.EMBED_MODEL || 'nomic-embed-text'
const MAX_DOCS = Number(env.MAX_DOCS || 100000)
const PAGES = Number(env.MAX_PAGES || 8)

function loadEnv(p) {
  try {
    return Object.fromEntries(readFileSync(p, 'utf8').split('\n')
      .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  } catch { return {} }
}
const log = (m) => console.log(`[rag] ${new Date().toISOString()} ${m}`)

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
function chunk(text, size = 1400, overlap = 180) {
  const t = text.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim()
  const out = []
  for (let i = 0; i < t.length && out.length < 12; i += size - overlap) out.push(t.slice(i, i + size))
  return out
}

async function main() {
  if (!URL || !JWT) throw new Error('DOC_RAG_URL and SUPABASE_ANON_JWT required in rag.env')
  log(`embed model=${EMBED_MODEL}`)
  let after = 0, done = 0, indexed = 0, chunksTot = 0
  while (done < MAX_DOCS) {
    const { targets, lastId, queried } = await edge({ mode: 'targets', after_id: after, limit: 12 })
    if (!queried) { log('no more documents'); break }
    for (const t of targets ?? []) {
      if (done >= MAX_DOCS) break
      done++
      let dir
      try {
        const pdf = Buffer.from(await (await fetch(t.url)).arrayBuffer())
        dir = mkdtempSync(join(tmpdir(), 'rag-'))
        writeFileSync(join(dir, 'in.pdf'), pdf)
        let src = join(dir, 'in.pdf')
        try { execFileSync('qpdf', ['--decrypt', src, join(dir, 'dec.pdf')], { stdio: 'ignore' }); src = join(dir, 'dec.pdf') } catch { /* not encrypted */ }
        execFileSync('pdftotext', ['-f', '1', '-l', String(PAGES), src, join(dir, 'out.txt')], { stdio: 'ignore' })
        const text = readFileSync(join(dir, 'out.txt'), 'utf8')
        if (text.replace(/\s/g, '').length < 40) { log(`skip ${t.filename} (no text layer — needs OCR)`); continue }
        const parts = chunk(text)
        const chunks = []
        for (const c of parts) chunks.push({ content: c, embedding: await embed(c) })
        const res = await edge({ mode: 'upsert', document_id: t.document_id, entity_type: t.entity_type, entity_id: t.entity_id, chunks })
        const n = Number(res.chunks) || 0
        if (n > 0) { indexed++; chunksTot += n; log(`+${n} chunks  ${t.filename}`) }
        else log(`0  ${t.filename}${res.error ? ` [${res.error}]` : ''}`)
      } catch (e) {
        log(`${t.filename}: ${String(e).slice(0, 90)}`)
      } finally { if (dir) rmSync(dir, { recursive: true, force: true }) }
    }
    if (lastId <= after) break
    after = lastId
  }
  log(`DONE: processed ${done} docs, indexed ${indexed}, ${chunksTot} chunks`)
}
main().catch((e) => { console.error(`[rag] ERROR: ${e.message}`); process.exit(1) })

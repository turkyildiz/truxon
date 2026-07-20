#!/usr/bin/env node
// Bulk Dropbox → Team Drive import (owner request 2026-07-20).
// Walks an extracted folder tree, stages every file under the Drive storage
// convention (<owner_uid>/<uuid12>_<name>, flat), bulk-uploads with
// `supabase storage cp -r`, then registers metadata (folders + files) through
// the doc-rag edge `drive_register` mode — which only accepts objects that
// really landed in the bucket. PDFs are picked up by the NAS indexer after.
//
// Usage:  node import-drive.mjs <extracted-dir> [--dry-run]
// Env (drive.env next to this script, chmod 600):
//   DOC_RAG_URL         https://<ref>.supabase.co/functions/v1/doc-rag
//   SUPABASE_ANON_JWT   public JWT-format anon token
//   OWNER_UID           storage path prefix (the admin's auth uid)
//   PROJECT_DIR         repo root with the linked supabase/ (for the CLI)

import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync, statSync, copyFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, dirname, basename, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { randomUUID } from 'node:crypto'

const HERE = dirname(fileURLToPath(import.meta.url))
const env = loadEnv(join(HERE, 'drive.env'))
const URL_ = env.DOC_RAG_URL
const JWT = env.SUPABASE_ANON_JWT
const OWNER = env.OWNER_UID
const PROJECT = env.PROJECT_DIR || join(HERE, '..', '..')
const MAX_BYTES = 100 * 1024 * 1024 // bucket per-file limit
const JUNK = new Set(['.DS_Store', 'Thumbs.db', 'desktop.ini', '.dropbox', '.dropbox.cache'])

const SRC = process.argv[2]
const DRY = process.argv.includes('--dry-run')

function loadEnv(p) {
  try {
    return Object.fromEntries(readFileSync(p, 'utf8').split('\n')
      .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  } catch { return {} }
}
const log = (m) => console.log(`[import] ${new Date().toISOString()} ${m}`)

function* walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    const st = statSync(p)
    if (st.isDirectory()) { if (!JUNK.has(name)) yield* walk(p) }
    else yield { path: p, size: st.size, name }
  }
}

const MIME = {
  pdf: 'application/pdf', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
  doc: 'application/msword', docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xls: 'application/vnd.ms-excel', xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  csv: 'text/csv', txt: 'text/plain', zip: 'application/zip', heic: 'image/heic',
}
const mimeOf = (n) => MIME[n.split('.').pop()?.toLowerCase() ?? ''] ?? 'application/octet-stream'
const clean = (s) => s.replace(/[^A-Za-z0-9._ ()&-]/g, '_').trim()

async function register(batch) {
  const r = await fetch(URL_, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${JWT}` },
    body: JSON.stringify({ mode: 'drive_register', files: batch }),
  })
  return r.json()
}

async function main() {
  if (!SRC) throw new Error('usage: node import-drive.mjs <extracted-dir> [--dry-run]')
  if (!URL_ || !JWT || !OWNER) throw new Error('DOC_RAG_URL, SUPABASE_ANON_JWT, OWNER_UID required in drive.env')

  // 1. survey
  const files = []
  let skippedJunk = 0, skippedBig = 0, skippedEmpty = 0
  for (const f of walk(SRC)) {
    if (JUNK.has(f.name) || f.name.startsWith('~$')) { skippedJunk++; continue }
    if (f.size === 0) { skippedEmpty++; continue }
    if (f.size > MAX_BYTES) { log(`too big (>100MB), skipping: ${relative(SRC, f.path)}`); skippedBig++; continue }
    files.push(f)
  }
  const totalMB = Math.round(files.reduce((s, f) => s + f.size, 0) / 1e6)
  log(`${files.length} files (${totalMB} MB) — skipped: ${skippedJunk} junk, ${skippedEmpty} empty, ${skippedBig} oversize`)
  if (DRY) { for (const f of files.slice(0, 20)) log(`  ${relative(SRC, f.path)}`); return }

  // 2. stage flat under the storage convention; remember each file's tree spot
  const stage = join(HERE, '.stage', OWNER)
  rmSync(join(HERE, '.stage'), { recursive: true, force: true })
  mkdirSync(stage, { recursive: true })
  const manifest = []
  for (const f of files) {
    const object = `${randomUUID().slice(0, 12)}_${clean(f.name)}`
    copyFileSync(f.path, join(stage, object))
    const parent = relative(SRC, dirname(f.path)).split('/').filter((s) => s && s !== '.').map(clean).join('/')
    manifest.push({
      storage_path: `${OWNER}/${object}`, filename: f.name, parent,
      content_type: mimeOf(f.name), size_bytes: f.size,
    })
  }
  writeFileSync(join(HERE, 'manifest.json'), JSON.stringify(manifest, null, 1))
  log(`staged ${manifest.length} files → uploading (one bulk cp)…`)

  // 3. bulk upload (CLI is linked in PROJECT_DIR). cp -r keeps the source dir's
  // basename as the remote prefix, so upload the <owner-uid> dir itself.
  // stdio ignored: the CLI logs one JSON line per file — thousands of files
  // overflow a piped buffer (ENOBUFS).
  execFileSync('supabase', ['storage', 'cp', '-r', stage, 'ss:///team/', '--experimental'],
    { cwd: PROJECT, stdio: 'ignore' })

  // 4. register metadata in batches of 40
  let ins = 0, fold = 0, skip = 0
  for (let i = 0; i < manifest.length; i += 40) {
    const res = await register(manifest.slice(i, i + 40))
    ins += res.inserted ?? 0; fold += res.folders ?? 0; skip += res.skipped ?? 0
    log(`registered ${Math.min(i + 40, manifest.length)}/${manifest.length} (+${res.inserted ?? 0}${res.error ? ` [${res.error}]` : ''})`)
  }
  rmSync(join(HERE, '.stage'), { recursive: true, force: true })
  log(`DONE: ${ins} files registered, ${fold} folders created, ${skip} skipped`)
  log('PDFs will be picked up by the NAS indexer automatically.')
}
main().catch((e) => { console.error(`[import] ERROR: ${e.message}`); process.exit(1) })

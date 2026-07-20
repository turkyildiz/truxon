#!/usr/bin/env node
// Merge an assisted ITS capture into the accumulated staging file.
//
// Why this exists: ITS's login is behind Cloudflare Turnstile, which blocks any
// automated (headless/Playwright) browser — and defeating bot-detection is off
// the table. So the delta is captured *assisted*: through a real, human-logged-in
// browser (the harvester JS in ITS_EXTRACTION.md, run via the live tab), which
// yields an array of load objects. This script folds that array into
// its_loads_full.json (deduped by ITS editId, updated when a load's material
// fields change) and drops a dated snapshot. It NEVER touches prod — the cutover
// import (import.mjs) reads its_loads_full.json and is idempotent.
//
// Usage:
//   node merge-its.mjs captured.json      # merge a captured-loads JSON array
//   node merge-its.mjs -                   # read the JSON array from stdin

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const ACCUM = join(HERE, 'its_loads_full.json')
const SNAPDIR = join(HERE, 'its_delta')

const src = process.argv[2]
if (!src) { console.error('usage: node merge-its.mjs <captured.json | ->'); process.exit(1) }
const raw = src === '-' ? readFileSync(0, 'utf8') : readFileSync(src, 'utf8')
let fresh
try { fresh = JSON.parse(raw) } catch (e) { console.error('input is not valid JSON:', e.message); process.exit(1) }
if (!Array.isArray(fresh)) { console.error('input must be a JSON array of load objects'); process.exit(1) }

// sanity: every load needs an editId + loadNum
const bad = fresh.filter((L) => !L?.meta?.editId || !L?.meta?.loadNum)
if (bad.length) { console.error(`refusing: ${bad.length} load(s) missing meta.editId/meta.loadNum`); process.exit(1) }

const byEdit = new Map()
if (existsSync(ACCUM)) {
  try { for (const L of JSON.parse(readFileSync(ACCUM, 'utf8'))) byEdit.set(L.meta.editId, L) } catch { /* start fresh */ }
}
const sig = (x) => JSON.stringify([x.status, x.total_rate, x.total_miles, x.driver, x.truck, x.stops])
let added = 0, updated = 0
for (const L of fresh) {
  const prev = byEdit.get(L.meta.editId)
  if (!prev) { byEdit.set(L.meta.editId, L); added++ }
  else if (sig(prev) !== sig(L)) { byEdit.set(L.meta.editId, L); updated++ }
}

const all = [...byEdit.values()]
writeFileSync(ACCUM, JSON.stringify(all, null, 1))
mkdirSync(SNAPDIR, { recursive: true })
// snapshot name from the capture's own timestamp (avoid Date.now nondeterminism note: fine here)
const stamp = (fresh[0]?.meta?.capturedAt || new Date().toISOString()).slice(0, 10)
writeFileSync(join(SNAPDIR, `${stamp}.json`), JSON.stringify(fresh, null, 1))

console.log(`merged: +${added} new, ~${updated} updated → ${all.length} loads accumulated in its_loads_full.json`)
console.log(`snapshot: its_delta/${stamp}.json`)
console.log('nothing written to prod. run import.mjs at cutover.')

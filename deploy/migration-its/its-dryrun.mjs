#!/usr/bin/env node
// ITS delta dry-run — maps a captured/accumulated ITS file against live prod
// WITHOUT writing anything: which loads are new vs already-in, whether every
// customer/driver/truck resolves, and which flags need fixing before cutover.
// Also prints the max ITS editId already in prod → paste as FLOOR in
// its-harvest.js so the probe sweep knows where to stop.
//
// Reads prod via customer-enrich mode=migration_refs (read-only, cron-gated):
//   CRON_SECRET=<value> node its-dryrun.mjs [its_loads_full.json]
// (CRON_SECRET comes from the owner / Supabase edge secrets; never stored here.)

import { readFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = process.argv[2] || join(HERE, 'its_loads_full.json')
const URL_FN = process.env.SUPABASE_FN_URL || 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/customer-enrich'
// anon key is public-safe (RLS enforces access) — same default as mobile/build-apk.sh
const ANON = process.env.SUPABASE_ANON_KEY || 'sb_publishable_Ak8T-1XgtjC00LXbiI9xDA_o5b_n7C-'
const CRON = process.env.CRON_SECRET
if (!CRON) { console.error('CRON_SECRET env var required (owner-held; gates the read-only prod refs endpoint)'); process.exit(1) }

const TRUCK_ALIASES = { '003': '03' } // ITS name → Truxon unit (AtoB canonical)
const norm = (s) => (s || '').trim().toLowerCase().replace(/\s+/g, ' ')

const refs = await (await fetch(URL_FN, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ANON}`, apikey: ANON, 'x-cron-key': CRON },
  body: JSON.stringify({ mode: 'migration_refs' }),
})).json()
if (!refs.existing_loads) { console.error('migration_refs failed:', JSON.stringify(refs).slice(0, 200)); process.exit(1) }

const prodCustomers = new Set(refs.customers.map(norm))
const prodDrivers = new Set(refs.drivers.map(norm))
const prodTrucks = new Set(refs.trucks.map(norm))
const prodEditIds = new Set(refs.existing_loads.map((l) => l.its).filter(Boolean))
const prodLoadNums = new Set(refs.existing_loads.map((l) => String(l.n)))
const floor = Math.max(0, ...[...prodEditIds].map(Number))

console.log(`prod refs: ${prodCustomers.size} customers · ${prodDrivers.size} drivers · ${prodTrucks.size} trucks · ${prodEditIds.size} ITS-marked loads`)
console.log(`FLOOR (max editId already in prod) = ${floor}  ← paste into its-harvest.js\n`)

if (!existsSync(SRC)) { console.log(`no capture file at ${SRC} — run the harvest first (FLOOR above is ready).`); process.exit(0) }
const loads = JSON.parse(readFileSync(SRC, 'utf8'))

let newN = 0, dupN = 0
const missingCustomers = new Set(), missingDrivers = new Set(), missingTrucks = new Set(), flags = []
for (const L of loads) {
  const already = prodEditIds.has(L.meta.editId) || prodLoadNums.has(String(L.meta.loadNum))
  if (already) { dupN++; continue }
  newN++
  if (L.customer_name && !prodCustomers.has(norm(L.customer_name))) missingCustomers.add(L.customer_name)
  if (L.driver && !prodDrivers.has(norm(L.driver))) missingDrivers.add(L.driver)
  const truck = TRUCK_ALIASES[L.truck] || L.truck
  if (truck && !prodTrucks.has(norm(truck))) missingTrucks.add(L.truck)
  if (!(Number(L.total_rate) > 0)) flags.push(`load ${L.meta.loadNum}: rate "${L.total_rate}" — fix in ITS before cutover`)
  if (!L.stops.length) flags.push(`load ${L.meta.loadNum}: no stops captured`)
}

console.log(`capture: ${loads.length} loads → ${newN} NEW to import, ${dupN} already in prod (idempotency will skip)`)
const list = (label, s, note = '') => console.log(`${label}: ${s.size ? [...s].join(' | ') : 'all matched ✓'}${s.size && note ? `\n  ${note}` : ''}`)
list('customers not in prod', missingCustomers, 'import.mjs auto-creates these — eyeball for typos/dupes first')
list('drivers not in prod', missingDrivers, 'import.mjs auto-creates — verify these are real new hires, not misspellings')
list('trucks not in prod', missingTrucks, 'NO auto-create for trucks — add the unit or extend TRUCK_ALIASES')
if (flags.length) { console.log('\nflags:'); flags.forEach((f) => console.log('  ' + f)) }
console.log('\nnothing was written to prod.')

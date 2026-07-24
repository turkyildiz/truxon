#!/usr/bin/env node
// Reflect QBO's billing onto the loads that the "unbilled" list wrongly shows.
//
// The unbilled section = completed loads with no invoice_id, and invoice_id was
// never populated — so loads QBO already invoiced (mostly the ITS-imported
// "Invoiced" loads) sat on the leak list. This links each such load to its live
// QBO mirror invoice (matched by the LOAD <ref> = reference_number) and marks it
// billed. Billing truth stays QBO; this only reflects it in Truxon.
//
// Safe by construction: dry-run first (shows the exact live list), and the flip
// only happens after you type FLIP. acct_reconcile_qbo_billing is idempotent and
// only ever touches completed→billed with a non-void QBO match.
//
// Steps: 1) backfill invoices.qbo_load_refs from qbo_load_refs.json (the QBO
//        snapshot), 2) dry-run reconcile, 3) confirm, 4) flip.
//
// Usage: node reconcile_qbo_billing.mjs [--dry] [--yes]
//        --dry: stop after the dry-run (never writes the flip; refs still backfill)
//        --yes: skip the typed confirmation (for non-interactive re-runs)
//        Prompts for admin email/password, or set ADMIN_EMAIL / ADMIN_PASSWORD.
import { createClient } from '@supabase/supabase-js'
import { readFileSync, existsSync } from 'node:fs'
import { createInterface } from 'node:readline/promises'
import { getCreds } from './_creds.mjs'

const DIR = new URL('.', import.meta.url).pathname
const envPath = DIR + '../../frontend/.env.local'
const fileEnv = existsSync(envPath)
  ? Object.fromEntries(readFileSync(envPath, 'utf8').split('\n').filter((l) => l.includes('='))
      .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
  : {}
const SB_URL = process.env.SUPABASE_URL || fileEnv.VITE_SUPABASE_URL || 'https://okoeeyxxvzypjiumraxq.supabase.co'
const SB_ANON = process.env.SUPABASE_ANON_KEY || fileEnv.VITE_SUPABASE_ANON_KEY || 'sb_publishable_Ak8T-1XgtjC00LXbiI9xDA_o5b_n7C-'
const sb = createClient(SB_URL, SB_ANON)
const DRY = process.argv.includes('--dry')
const YES = process.argv.includes('--yes')

const money = (n) => '$' + Number(n || 0).toLocaleString('en-US', { maximumFractionDigits: 0 })

const { email, password } = await getCreds()
const { error: loginErr } = await sb.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('login failed:', loginErr.message); process.exit(1) }

// 1) backfill the LOAD refs onto existing QBO mirror rows
const refRows = JSON.parse(readFileSync(DIR + 'qbo_load_refs.json', 'utf8'))
process.stdout.write(`backfilling qbo_load_refs onto ${refRows.length} QBO invoices… `)
const { data: nBack, error: backErr } = await sb.rpc('qbo_backfill_load_refs', { p_rows: refRows })
if (backErr) { console.error('\nbackfill failed:', backErr.message); process.exit(1) }
console.log(`${nBack} rows populated (rows that already had refs are skipped).`)

// 2) dry-run reconcile — exactly what WOULD flip, against live prod
const { data: dry, error: dryErr } = await sb.rpc('acct_reconcile_qbo_billing', { p_dry_run: true })
if (dryErr) { console.error('dry-run failed:', dryErr.message); process.exit(1) }

const rows = dry.rows || []
console.log(`\n── DRY RUN (nothing written) ──`)
console.log(`would link ${dry.matched} completed loads → billed  =  ${money(dry.matched_total)}`)
console.log(`would remain unbilled (no QBO match): ${dry.still_unbilled}\n`)
for (const r of rows.slice(0, 200)) {
  const flag = r.amount_matches ? '' : `  ⚠ rate ${money(r.rate)} vs QBO ${money(r.invoice_total)}`
  console.log(`  load ${r.load_number}  ref ${r.reference}  ${money(r.rate)}  → QBO ${r.qbo_doc} (${r.invoice_status})${flag}`)
}
if (rows.length > 200) console.log(`  … and ${rows.length - 200} more`)

if (DRY) { console.log('\n--dry: stopping before the flip. Nothing was billed.'); process.exit(0) }
if (dry.matched === 0) { console.log('\nnothing to link. done.'); process.exit(0) }

// 3) confirm
if (!YES) {
  const rl = createInterface({ input: process.stdin, output: process.stdout })
  const ans = await rl.question(`\nType FLIP to mark these ${dry.matched} loads billed (anything else aborts): `)
  rl.close()
  if (ans.trim() !== 'FLIP') { console.log('aborted — nothing written.'); process.exit(0) }
}

// 4) flip
const { data: done, error: doneErr } = await sb.rpc('acct_reconcile_qbo_billing', { p_dry_run: false })
if (doneErr) { console.error('flip failed:', doneErr.message); process.exit(1) }
console.log(`\n✓ linked ${done.linked} loads → billed  (${money(done.matched_total)}).  ${done.still_unbilled} remain on the unbilled list.`)

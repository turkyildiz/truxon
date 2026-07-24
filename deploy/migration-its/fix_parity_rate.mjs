#!/usr/bin/env node
// One-off from the 2026-07-24 ITS↔prod parity sweep: the only rate discrepancy
// across 1073 invoiced loads was load 1141 — ITS $2190 vs prod $2100 (a $90
// accessorial ITS folds into total_rate). Per owner: bump the line-haul to match.
// Usage: node fix_parity_rate.mjs [--dry]   (prompts for admin email/password)
import { createClient } from '@supabase/supabase-js'
import { readFileSync, existsSync } from 'node:fs'
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
const { email, password } = await getCreds()
const { error: loginErr } = await sb.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('login failed:', loginErr.message); process.exit(1) }

const FIXES = [{ load_number: '1141', new_rate: 2190.00, old_expected: 2100.00 }]
for (const f of FIXES) {
  const { data: rows, error } = await sb.from('loads').select('id, load_number, rate, status').eq('load_number', f.load_number).limit(1)
  if (error) { console.log(f.load_number + ': lookup error — ' + error.message); continue }
  const l = rows && rows[0]
  if (!l) { console.log(f.load_number + ': not found'); continue }
  console.log(`${f.load_number}: current rate $${l.rate} (status ${l.status}) → target $${f.new_rate}`)
  if (Number(l.rate) === f.new_rate) { console.log('  already correct — skip'); continue }
  if (DRY) { console.log('  (dry — would update)'); continue }
  const { error: uErr } = await sb.from('loads').update({ rate: f.new_rate }).eq('id', l.id)
  if (uErr) { console.log('  UPDATE FAILED — ' + uErr.message); continue }
  const { data: after } = await sb.from('loads').select('rate').eq('id', l.id).single()
  console.log('  updated → $' + after.rate + (Number(after.rate) === f.new_rate ? ' ✓' : ' (mismatch!)'))
}
console.log('done.' + (DRY ? ' (dry run)' : ''))

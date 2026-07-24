#!/usr/bin/env node
// Trigger a full QBO sync now (instead of waiting for the 30-min cron) and let
// the edge fn's self-heal reconcile run. Unlike the local qbo_load_refs.json
// backfill (which only covered the 2-page snapshot, docs 2539-4551), this
// mirrors EVERY QBO invoice with its LOAD refs, so loads invoiced under any doc
// number get linked. Whatever's still unbilled after this is genuinely not
// invoiced in QBO — the real go-live signal.
//
// Read-through: the self-heal inside qbo-sync only ever links completed→billed
// on a non-void QBO match (idempotent). Prints the final still-unbilled count.
//
// Usage: node sync_and_reconcile.mjs   (prompts for admin email/password)
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

const { email, password } = await getCreds()
const { error: loginErr } = await sb.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('login failed:', loginErr.message); process.exit(1) }

console.log('triggering a full QBO pull (mirror every invoice + self-heal)… this fetches ~2k invoices, ~30-60s\n')
const { data, error } = await sb.functions.invoke('qbo-sync', { body: { mode: 'pull' } })
if (error) {
  // functions.invoke surfaces non-2xx as an error with a context body
  let body = ''
  try { body = await error.context?.text?.() } catch { /* ignore */ }
  console.error('pull failed:', error.message, body || '')
  process.exit(1)
}
console.log('pull result:')
console.log(JSON.stringify(data, null, 2))
if (data && typeof data === 'object') {
  console.log(`\n→ inserted ${data.inserted ?? '?'} / updated ${data.updated ?? '?'} invoices`)
  console.log(`→ self-heal linked ${data.reconcile_linked ?? '?'} more loads → billed`)
  console.log(`→ still unbilled (genuinely no QBO invoice): ${data.reconcile_still_unbilled ?? '?'}`)
}

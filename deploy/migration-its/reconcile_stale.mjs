#!/usr/bin/env node
// Advance the stale in_transit loads that the ITS delta import collided with.
// These 9 loads were 'in_transit' in prod (frozen at bulk-import time ~Jul 15)
// but are "Invoiced" in ITS now (verified load-by-load) — their runs are done,
// their drivers have moved to the current loads. STATUS_MAP maps ITS Invoiced →
// 'completed', so we advance each to completed (one step at a time via the
// guarded RPC), which reflects reality AND frees the driver so the delta import
// can assign them. 1136 is deliberately NOT here — it's genuinely "Unloading".
//
// Usage: node reconcile_stale.mjs [--dry]   (prompts for admin email/password;
//        or set ADMIN_EMAIL / ADMIN_PASSWORD env vars to skip the prompt)
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

const STALE = ['1138', '1141', '1142', '1145', '1146', '1147', '1148', '1149', '1150']
const ORDER = ['pending', 'assigned', 'in_transit', 'delivered', 'completed', 'billed']
const TARGET = 'completed'

console.log((DRY ? 'DRY — ' : '') + 'advancing ' + STALE.length + ' stale invoiced loads → ' + TARGET + '\n')
let ok = 0
for (const ln of STALE) {
  const { data: rows, error } = await sb.from('loads').select('id, load_number, status').eq('load_number', ln).limit(1)
  if (error) { console.log('  ' + ln + ': lookup error — ' + error.message); continue }
  const l = rows && rows[0]
  if (!l) { console.log('  ' + ln + ': not found in prod'); continue }
  let cur = l.status
  if (ORDER.indexOf(cur) >= ORDER.indexOf(TARGET)) { console.log('  ' + ln + ': already ' + cur + ' — skip'); ok++; continue }
  if (DRY) { console.log('  ' + ln + ': ' + cur + ' → ' + TARGET + ' (would advance)'); continue }
  const start = cur
  while (ORDER.indexOf(cur) < ORDER.indexOf(TARGET)) {
    const next = ORDER[ORDER.indexOf(cur) + 1]
    const { error: e } = await sb.rpc('change_load_status', { p_load_id: l.id, p_status: next })
    if (e) { console.log('  ' + ln + ': FAILED ' + cur + '→' + next + ' — ' + e.message); break }
    cur = next
  }
  if (cur === TARGET) ok++
  console.log('  ' + ln + ': ' + start + ' → ' + cur + (cur === TARGET ? ' ✓' : ' (stopped)'))
}
console.log('\ndone — ' + ok + '/' + STALE.length + ' at ' + TARGET + (DRY ? ' (dry run, nothing written)' : ''))

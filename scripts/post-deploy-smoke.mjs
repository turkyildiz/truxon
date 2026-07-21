#!/usr/bin/env node
/**
 * Post-deploy smoke against live Supabase (anon + admin login).
 * Usage:
 *   node scripts/post-deploy-smoke.mjs
 * Requires frontend/.env.local with VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY
 * and env ADMIN_EMAIL / ADMIN_PASSWORD (env only — argv lands in shell history).
 */
import { createClient } from '@supabase/supabase-js'
import { readFileSync, existsSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const envPath = resolve(root, 'frontend/.env.local')
if (!existsSync(envPath)) {
  console.error('Missing frontend/.env.local — copy from your production machine')
  process.exit(2)
}
const env = Object.fromEntries(
  readFileSync(envPath, 'utf8').split('\n').filter((l) => l.includes('=')).map((l) => {
    const i = l.indexOf('=')
    return [l.slice(0, i).trim(), l.slice(i + 1).trim()]
  }),
)
const url = env.VITE_SUPABASE_URL
const anon = env.VITE_SUPABASE_ANON_KEY
const email = process.env.ADMIN_EMAIL
const password = process.env.ADMIN_PASSWORD
if (!url || !anon || !email || !password) {
  console.error('Need URL/anon in .env.local and ADMIN_EMAIL/ADMIN_PASSWORD in the environment')
  process.exit(2)
}

const sb = createClient(url, anon)
let pass = 0, fail = 0
function ok(label, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'} ${label} ${extra}`)
  cond ? pass++ : fail++
}

// anon blocked-ish
const { data: anonRows } = await sb.from('customers').select('id').limit(1)
ok('anon cannot freely read customers (empty or error)', !anonRows?.length)

const { error: loginErr } = await sb.auth.signInWithPassword({ email, password })
ok('admin login', !loginErr, loginErr?.message ?? '')

if (!loginErr) {
  const { data: prof } = await sb.from('profiles').select('role').maybeSingle()
  ok('profile loaded', !!prof)

  // companion RPCs exist
  for (const name of ['driver_my_loads', 'fleet_positions_snapshot', 'my_driver_id']) {
    const { error } = await sb.rpc(name)
    // may fail on permission — existence matters
    ok(`rpc ${name} reachable`, !error || !/could not find|PGRST202/i.test(error.message), error?.message ?? 'ok')
  }

  // void_invoice paid guard: only checks function exists via schema if possible
  const { error: dashErr } = await sb.rpc('dashboard_summary')
  ok('dashboard_summary (staff)', !dashErr, dashErr?.message ?? '')
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)

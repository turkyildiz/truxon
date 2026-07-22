// Truxon load/stress harness. Escalates concurrency per vector against the
// LIVE Supabase project and records latency percentiles + error rate at each
// level; a vector's "breakpoint" is the first level where error rate > 2% or
// p95 latency > 5s. Read vectors only by default (safe on production);
// pass --writes to include a cleaned-up write burst.
//
// Usage: ADMIN_EMAIL=… ADMIN_PASSWORD=… node stress.mjs [--writes] [--max=200]
import { createClient } from '@supabase/supabase-js'
import { readFileSync, writeFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
// creds from env only (review M-6): argv lands in shell history + ps -ef
const email = process.env.ADMIN_EMAIL, password = process.env.ADMIN_PASSWORD
const flags = process.argv.slice(2)
const WRITES = flags.includes('--writes')
const MAX = Number((flags.find((f) => f.startsWith('--max=')) || '--max=200').split('=')[1])
const LEVELS = [1, 5, 10, 25, 50, 100, 200, 400].filter((n) => n <= MAX)

const mk = () => createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)
const authed = mk()
{
  const { error } = await authed.auth.signInWithPassword({ email, password })
  if (error) { console.error('login failed:', error.message); process.exit(1) }
}

const pct = (arr, p) => (arr.length ? arr.slice().sort((a, b) => a - b)[Math.min(arr.length - 1, Math.floor((p / 100) * arr.length))] : 0)

async function runLevel(fn, n) {
  const lat = []
  let errors = 0
  const errSamples = []
  const started = Date.now()
  await Promise.all(
    Array.from({ length: n }, async () => {
      const t = Date.now()
      try {
        const { error } = await fn(authed)
        if (error) { errors++; if (errSamples.length < 3) errSamples.push(error.message) }
      } catch (e) {
        errors++
        if (errSamples.length < 3) errSamples.push(String(e).slice(0, 80))
      }
      lat.push(Date.now() - t)
    }),
  )
  const wall = Date.now() - started
  return {
    n, errors, errorRate: +(errors / n).toFixed(3),
    p50: pct(lat, 50), p95: pct(lat, 95), p99: pct(lat, 99), max: Math.max(...lat),
    throughput: +((n / wall) * 1000).toFixed(1), errSamples,
  }
}

const VECTORS = {
  dashboard: (c) => c.rpc('dashboard_summary'),
  list_loads: (c) => c.from('loads').select('*, customer:customers(company_name), driver:drivers(full_name)').order('created_at', { ascending: false }).limit(200),
  global_search: (c) => c.rpc('global_search', { q: 'log' }),
  weekly_report: (c) => c.rpc('weekly_report', { p_week_of: '2026-07-13' }),
  load_detail: (c) => c.from('loads').select('*, load_stops(*)').eq('load_number', '1136').single(),
  list_customers: (c) => c.from('customers').select('*').order('company_name'),
}

const report = { started: null, project: env.VITE_SUPABASE_URL, levels: LEVELS, vectors: {} }

for (const [name, fn] of Object.entries(VECTORS)) {
  console.log(`\n=== ${name} ===`)
  const results = []
  let breakpoint = null
  for (const n of LEVELS) {
    const r = await runLevel(fn, n)
    results.push(r)
    console.log(`  n=${String(n).padStart(3)}  err=${(r.errorRate * 100).toFixed(1)}%  p50=${r.p50}ms  p95=${r.p95}ms  p99=${r.p99}ms  thru=${r.throughput}/s${r.errSamples.length ? '  ' + r.errSamples[0] : ''}`)
    if (!breakpoint && (r.errorRate > 0.02 || r.p95 > 5000)) breakpoint = n
    await new Promise((res) => setTimeout(res, 800)) // let the pool recover between levels
  }
  report.vectors[name] = { results, breakpoint }
  if (breakpoint) console.log(`  ⚠ breakpoint at n=${breakpoint}`)
}

// ---- controlled write burst (optional) ----
if (WRITES) {
  console.log('\n=== write_burst (loads create+delete) ===')
  const { data: cust } = await authed.from('customers').select('id').limit(1).single()
  const created = []
  const wr = await runLevel(async (c) => {
    const { data, error } = await c.from('loads').insert({ customer_id: cust.id, status: 'pending', rate: 1, miles: 1, notes: '[STRESS TEST]' }).select('id').single()
    if (data) created.push(data.id)
    return { error }
  }, 100)
  console.log(`  create x100: err=${(wr.errorRate * 100).toFixed(1)}%  p95=${wr.p95}ms  thru=${wr.throughput}/s`)
  // cleanup
  if (created.length) await authed.from('loads').delete().in('id', created)
  console.log(`  cleaned up ${created.length} test loads (load numbers were consumed from the sequence)`)
  report.write_burst = { ...wr, cleaned: created.length }
}

report.started = 'see filename timestamp'
writeFileSync(new URL('./stress_report.json', import.meta.url).pathname, JSON.stringify(report, null, 1))
console.log('\nreport → deploy/stress/stress_report.json')

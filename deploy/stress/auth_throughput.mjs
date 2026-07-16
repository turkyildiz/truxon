// Auth throughput stress test against LIVE Supabase Auth (GoTrue).
// Fires concurrent signInWithPassword calls at escalating concurrency,
// records success rate + latency percentiles + 429/lockout signals.
// Then a wrong-password storm, and verifies the real account still logs in.
// READ-ONLY: no DB writes, no settings/role/password changes.
import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const URL = env.VITE_SUPABASE_URL
const KEY = env.VITE_SUPABASE_ANON_KEY
const EMAIL = 'turkyildiz@gmail.com'
const PASS = 'Towtruck505.'

// Each attempt gets a fresh client with persistSession off so we exercise the
// auth endpoint, not a cached token.
const mk = () => createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } })

const pct = (arr, p) => {
  if (!arr.length) return 0
  const s = arr.slice().sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]
}
const mean = (a) => (a.length ? Math.round(a.reduce((x, y) => x + y, 0) / a.length) : 0)

async function attempt(pw) {
  const c = mk()
  const t = Date.now()
  try {
    const { data, error } = await c.auth.signInWithPassword({ email: EMAIL, password: pw })
    const ms = Date.now() - t
    if (error) return { ok: false, ms, status: error.status, msg: error.message, code: error.code }
    return { ok: !!data?.session, ms, status: 200 }
  } catch (e) {
    return { ok: false, ms: Date.now() - t, status: 'throw', msg: String(e && e.message || e) }
  }
}

async function runLevel(n, pw = PASS) {
  const started = Date.now()
  const res = await Promise.all(Array.from({ length: n }, () => attempt(pw)))
  const wall = Date.now() - started
  const lat = res.map((r) => r.ms)
  const ok = res.filter((r) => r.ok).length
  const errs = res.filter((r) => !r.ok)
  const byStatus = {}
  for (const r of errs) byStatus[r.status] = (byStatus[r.status] || 0) + 1
  const rate429 = errs.filter((r) => r.status === 429).length
  const samples = [...new Set(errs.map((r) => `${r.status}:${r.msg}`))].slice(0, 4)
  return {
    n, ok, fail: errs.length, successRate: +(100 * ok / n).toFixed(1),
    wallMs: wall, throughputPerSec: +(1000 * n / wall).toFixed(1),
    p50: pct(lat, 50), p90: pct(lat, 90), p95: pct(lat, 95), p99: pct(lat, 99),
    min: Math.min(...lat), max: Math.max(...lat), mean: mean(lat),
    rate429, byStatus, samples,
  }
}

const out = { startedAt: new Date().toISOString(), url: URL, email: EMAIL, levels: [], wrongPwStorm: null, recoveryLogin: null }

console.error('=== VALID-CRED CONCURRENCY ESCALATION ===')
for (const n of [10, 25, 50, 100]) {
  const r = await runLevel(n, PASS)
  out.levels.push(r)
  console.error(`n=${r.n} ok=${r.ok}/${r.n} (${r.successRate}%) 429=${r.rate429} p50=${r.p50} p95=${r.p95} p99=${r.p99} max=${r.max}ms tput=${r.throughputPerSec}/s status=${JSON.stringify(r.byStatus)}`)
  if (r.samples.length) console.error('   samples:', JSON.stringify(r.samples))
  await new Promise((res) => setTimeout(res, 1500)) // brief gap between levels
}

console.error('\n=== WRONG-PASSWORD STORM (25 concurrent bad logins) ===')
out.wrongPwStorm = await runLevel(25, 'WrongPass_' + Date.now())
const w = out.wrongPwStorm
console.error(`n=${w.n} authAccepted=${w.ok} rejected=${w.fail} 429=${w.rate429} p50=${w.p50} p95=${w.p95} status=${JSON.stringify(w.byStatus)}`)
if (w.samples.length) console.error('   samples:', JSON.stringify(w.samples))

console.error('\n=== RECOVERY: correct login after bad-password storm ===')
await new Promise((res) => setTimeout(res, 1000))
out.recoveryLogin = await attempt(PASS)
console.error('recovery:', JSON.stringify(out.recoveryLogin))

out.finishedAt = new Date().toISOString()
console.log('\n__JSON_START__')
console.log(JSON.stringify(out, null, 2))
console.log('__JSON_END__')

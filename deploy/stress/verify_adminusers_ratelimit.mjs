import { createClient } from '@supabase/supabase-js'
import fs from 'node:fs'

const env = fs.readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim()
const anon = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim()

const sb = createClient(url, anon)
const { data: auth, error: authErr } = await sb.auth.signInWithPassword({
  email: 'turkyildiz@gmail.com', password: 'Towtruck505',
})
if (authErr) { console.error('AUTH FAIL', authErr.message); process.exit(1) }
const token = auth.session.access_token
const fnUrl = `${url}/functions/v1/admin-users`

async function oneCall() {
  const t0 = Date.now()
  const res = await fetch(fnUrl, {
    method: 'GET',
    headers: { Authorization: `Bearer ${token}`, apikey: anon },
  })
  const body = await res.text()
  const ms = Date.now() - t0
  let count = null
  try { count = JSON.parse(body).length } catch {}
  return { status: res.status, ms, count, rlHeader: res.headers.get('x-ratelimit-remaining') || res.headers.get('ratelimit-remaining') }
}

// warmup
const w = await oneCall()
console.log('warmup:', w.status, w.ms + 'ms', 'rows=' + w.count)

const N = 30
const t0 = Date.now()
const results = await Promise.all(Array.from({ length: N }, oneCall))
const wall = Date.now() - t0

const lat = results.map(r => r.ms).sort((a, b) => a - b)
const codes = {}
results.forEach(r => { codes[r.status] = (codes[r.status] || 0) + 1 })
const pct = p => lat[Math.min(lat.length - 1, Math.floor(p / 100 * lat.length))]
console.log(`\n${N} concurrent GET /admin-users, wall=${wall}ms`)
console.log('status codes:', JSON.stringify(codes))
console.log(`latency ms: min=${lat[0]} p50=${pct(50)} p95=${pct(95)} max=${lat[lat.length-1]}`)
console.log('any 429 (rate limited)?', codes['429'] ? 'YES' : 'NO')
console.log('rate-limit header sample:', results[0].rlHeader)

// second heavier burst to see if any throttling kicks in
const N2 = 60
const r2 = await Promise.all(Array.from({ length: N2 }, oneCall))
const c2 = {}
r2.forEach(r => { c2[r.status] = (c2[r.status] || 0) + 1 })
console.log(`\n${N2} concurrent burst status codes:`, JSON.stringify(c2), '429?', c2['429'] ? 'YES' : 'NO')

await sb.auth.signOut()

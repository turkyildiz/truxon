import { createClient } from '@supabase/supabase-js'
import fs from 'node:fs'

const env = fs.readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim()
const anon = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim()

const fnUrl = `${url}/functions/v1/distance`

async function probe(token, label, n) {
  const body = JSON.stringify({ origin: 'Chicago, IL', destination: 'Dallas, TX' })
  const headers = { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}`, 'apikey': anon }
  const t0 = Date.now()
  const results = await Promise.all(Array.from({ length: n }, async () => {
    const s = Date.now()
    try {
      const r = await fetch(fnUrl, { method: 'POST', headers, body })
      const txt = await r.text()
      return { status: r.status, ms: Date.now() - s, body: txt.slice(0, 120) }
    } catch (e) { return { status: 'ERR', ms: Date.now() - s, body: String(e).slice(0, 80) } }
  }))
  const total = Date.now() - t0
  const codes = {}
  for (const r of results) codes[r.status] = (codes[r.status] || 0) + 1
  const lats = results.map(r => r.ms).sort((a, b) => a - b)
  const pct = p => lats[Math.min(lats.length - 1, Math.floor(p * lats.length))]
  const sample = results.find(r => r.status === 200) || results[0]
  console.log(`\n[${label}] n=${n} wall=${total}ms codes=${JSON.stringify(codes)}`)
  console.log(`  latency min=${lats[0]} p50=${pct(0.5)} p95=${pct(0.95)} max=${lats[lats.length-1]}`)
  console.log(`  sample body: ${sample.body}`)
  return { codes, results }
}

// 1) Anonymous (no auth) probe
const anonClient = createClient(url, anon)
await probe(anon, 'ANON (anon key as bearer, no user)', 5)

// 2) Authenticated admin probe
const admin = createClient(url, anon)
const { data: auth, error: aerr } = await admin.auth.signInWithPassword({ email: 'turkyildiz@gmail.com', password: 'Towtruck505' })
if (aerr) { console.log('LOGIN FAILED', aerr.message); process.exit(1) }
const token = auth.session.access_token
console.log('Logged in as admin, user:', auth.user.email)

// Warm single call to confirm real data
await probe(token, 'ADMIN warmup', 1)

// 50 concurrent (matches reported claim)
const burst = await probe(token, 'ADMIN 50 concurrent', 50)

// Second immediate burst to see if any throttling kicks in after volume
await probe(token, 'ADMIN 50 concurrent (2nd burst)', 50)

const ok = burst.results.filter(r => r.status === 200 && /"available":true/.test(r.body)).length
const billed = burst.results.filter(r => r.status === 200 && /"miles":\d/.test(r.body)).length
console.log(`\nSUMMARY: 200s with available:true = ${ok}/50, with real miles (billable) = ${billed}/50`)
console.log('Any 429 rate-limit responses:', burst.results.some(r => r.status === 429))
process.exit(0)

// Edge-function abuse & rate-limiting probe against the LIVE Truxon project.
// Authenticated as admin. Read-heavy; the only side effect is consuming the
// admin's extract_pdf rate-limit budget (30/hr, self-resets). No writes to
// real tables, no LLM spend (tiny PDF has no text layer -> needs_images 200).
import { createClient } from '/home/turkyildiz/TRUXON/frontend/node_modules/@supabase/supabase-js/dist/index.mjs'
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const URL_BASE = env.VITE_SUPABASE_URL
const ANON = env.VITE_SUPABASE_ANON_KEY
const FN = (n) => `${URL_BASE}/functions/v1/${n}`

const sb = createClient(URL_BASE, ANON)
const { data: auth, error: aerr } = await sb.auth.signInWithPassword({
  email: 'turkyildiz@gmail.com', password: 'Towtruck505',
})
if (aerr) { console.error('login failed:', aerr.message); process.exit(1) }
const JWT = auth.session.access_token
const H = { Authorization: `Bearer ${JWT}`, apikey: ANON }

// Minimal valid-ish PDF (no text layer -> avoids LLM call).
const tinyPdf = Buffer.from(
  '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n' +
  '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n' +
  '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\n' +
  'trailer<</Root 1 0 R>>\n%%EOF\n', 'latin1')

function form(pdfBuf, name = 'tiny.pdf') {
  const fd = new FormData()
  fd.append('file', new Blob([pdfBuf], { type: 'application/pdf' }), name)
  return fd
}

async function hit(url, opts) {
  const t = Date.now()
  try {
    const r = await fetch(url, opts)
    let body = ''
    try { body = (await r.text()).slice(0, 200) } catch {}
    return { status: r.status, ms: Date.now() - t, body }
  } catch (e) {
    return { status: 'NETERR', ms: Date.now() - t, body: String(e).slice(0, 160) }
  }
}

const tally = (arr) => {
  const t = {}
  for (const r of arr) t[r.status] = (t[r.status] || 0) + 1
  return t
}
const lats = (arr) => {
  const l = arr.map((r) => r.ms).sort((a, b) => a - b)
  const p = (q) => l[Math.min(l.length - 1, Math.floor(q * l.length))]
  return { min: l[0], p50: p(0.5), p95: p(0.95), max: l[l.length - 1] }
}

const out = {}

// ---- (2) FIRST: >15MB body -> expect 413 (must run before rate limit is spent) ----
{
  const big = Buffer.concat([tinyPdf, Buffer.alloc(16 * 1024 * 1024, 0x20)]) // ~16MB
  console.log(`\n[413 test] posting ~${(big.length / 1048576).toFixed(1)}MB body to extract-pdf`)
  const r = await hit(FN('extract-pdf'), { method: 'POST', headers: H, body: form(big, 'big.pdf') })
  console.log(`  -> ${r.status} in ${r.ms}ms  body=${r.body}`)
  out.oversize_413 = r
}

// ---- (1) extract-pdf ~40x rapid -> expect 429 after 30, no 500s ----
{
  console.log(`\n[rate-limit test] firing 40 extract-pdf requests`)
  const results = await Promise.all(
    Array.from({ length: 40 }, () => hit(FN('extract-pdf'), { method: 'POST', headers: H, body: form(tinyPdf) })),
  )
  const t = tally(results)
  console.log(`  statuses: ${JSON.stringify(t)}  lat=${JSON.stringify(lats(results))}`)
  const sample429 = results.find((r) => r.status === 429)
  const sampleOther = results.find((r) => r.status !== 429 && r.status !== 200)
  if (sample429) console.log(`  429 body: ${sample429.body}`)
  if (sampleOther) console.log(`  non-200/429 sample: ${sampleOther.status} ${sampleOther.body}`)
  out.rate_limit = { tally: t, latency: lats(results), sample429: sample429?.body, sampleOther }
}

// ---- (3) distance ~50x concurrent ----
{
  console.log(`\n[distance test] 50 concurrent`)
  const results = await Promise.all(
    Array.from({ length: 50 }, () => hit(FN('distance'), {
      method: 'POST', headers: { ...H, 'Content-Type': 'application/json' },
      body: JSON.stringify({ origin: 'Chicago, IL', destination: 'Dallas, TX' }),
    })),
  )
  const t = tally(results)
  console.log(`  statuses: ${JSON.stringify(t)}  lat=${JSON.stringify(lats(results))}`)
  const bad = results.find((r) => r.status !== 200)
  if (bad) console.log(`  non-200 sample: ${bad.status} ${bad.body}`)
  out.distance = { tally: t, latency: lats(results), sampleBody: results[0].body, bad }
}

// ---- (4) admin-users list ~30x concurrent ----
{
  console.log(`\n[admin-users test] 30 concurrent GET`)
  const results = await Promise.all(
    Array.from({ length: 30 }, () => hit(FN('admin-users'), { method: 'GET', headers: H })),
  )
  const t = tally(results)
  console.log(`  statuses: ${JSON.stringify(t)}  lat=${JSON.stringify(lats(results))}`)
  const bad = results.find((r) => r.status !== 200)
  if (bad) console.log(`  non-200 sample: ${bad.status} ${bad.body}`)
  // record row count from a good response
  const good = results.find((r) => r.status === 200)
  out.admin_users = { tally: t, latency: lats(results), bad, bodyHead: good?.body }
}

console.log('\n===JSON===')
console.log(JSON.stringify(out, null, 1))

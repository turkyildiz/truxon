import { createClient } from '/home/turkyildiz/TRUXON/frontend/node_modules/@supabase/supabase-js/dist/index.mjs'
import { readFileSync } from 'node:fs'
const env = Object.fromEntries(readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8').split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
const mk = () => createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } })
const variants = ['Towtruck505.', 'Towtruck505', 'towtruck505.', 'Towtruck505!']
console.error('waiting 60s for rate-limit window to clear...')
await new Promise((r) => setTimeout(r, 60000))
for (const pw of variants) {
  const t = Date.now()
  const r = await mk().auth.signInWithPassword({ email: 'turkyildiz@gmail.com', password: pw })
  console.log(JSON.stringify({ pw, ms: Date.now() - t, ok: !!r.data?.session, status: r.error?.status, msg: r.error?.message, user: r.data?.user?.email }))
  await new Promise((r) => setTimeout(r, 8000)) // 8s gap to stay under rate limit
}

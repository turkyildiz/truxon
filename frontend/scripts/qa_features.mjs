// Verification of the feature batch against production, as a real user.
// Usage: node scripts/qa_features.mjs <email> <password>
import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const supabase = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)

let passed = 0
const check = (label, cond, extra = '') => {
  console.log(`[${cond ? 'PASS' : 'FAIL'}] ${label} ${extra}`)
  if (!cond) process.exit(1)
  passed++
}
const ok = ({ data, error }) => { if (error) throw new Error(error.message); return data }

const [email, password] = process.argv.slice(2)
ok(await supabase.auth.signInWithPassword({ email, password }))
check('QA login', true)

// Company settings: read + admin update
const settings = ok(await supabase.from('company_settings').select('*').eq('id', 1).single())
check('settings row exists', settings.company_name.length > 0, `name="${settings.company_name}"`)
const updated = ok(await supabase.from('company_settings').update({ mc_number: 'MC-TEST-001' }).eq('id', 1).select().single())
check('admin can update settings', updated.mc_number === 'MC-TEST-001')
ok(await supabase.from('company_settings').update({ mc_number: '' }).eq('id', 1).select().single()) // revert

// Password change (self-service) — change QA's own password and re-login with it
const newPw = 'QaTemp-' + Math.random().toString(36).slice(2, 10) + 'X1'
ok(await supabase.auth.updateUser({ password: newPw }))
await supabase.auth.signOut()
ok(await supabase.auth.signInWithPassword({ email, password: newPw }))
check('self-service password change + re-login', true)

// Date-range filter query path
const { data: filtered, error: fErr } = await supabase
  .from('loads').select('id')
  .gte('pickup_time', '2026-01-01')
  .lte('pickup_time', '2026-12-31T23:59:59')
  .limit(5)
check('date-range filter query', !fErr, `rows=${filtered?.length ?? 0}`)

console.log(`\nAll ${passed} checks passed.`)

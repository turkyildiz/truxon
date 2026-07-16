// Backfill load_stops for migrated ITS loads (full itinerary, incl. the
// 123 multi-stop loads). Usage: node backfill_stops.mjs <email> <password> <migration_dir>
import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const sb = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)
const [email, password, dir] = process.argv.slice(2)
const { error: loginErr } = await sb.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('login failed:', loginErr.message); process.exit(1) }

const loads = JSON.parse(readFileSync(`${dir}/its_loads_full.json`, 'utf8'))
const idMap = JSON.parse(readFileSync(`${dir}/load_id_map.json`, 'utf8'))
const { data: existing } = await sb.from('load_stops').select('load_id').limit(1)
if (existing?.length) { console.log('load_stops already populated — aborting to stay idempotent'); process.exit(0) }

// Billed/locked loads: none are billed in Truxon (imported as completed), so
// the guard trigger allows inserts.
const iso = (s) => {
  if (!s?.date || s.date === '0000-00-00') return null
  let h = parseInt(s.h) || 0
  if (s.ap === 'PM' && h < 12) h += 12
  if (s.ap === 'AM' && h === 12) h = 0
  return `${s.date}T${String(h).padStart(2, '0')}:${String(parseInt(s.m) || 0).padStart(2, '0')}:00`
}

const rows = []
for (const L of loads) {
  const loadId = idMap[L.meta.editId]
  if (!loadId) continue
  let pu = 0, del = 0
  for (const s of L.stops) {
    rows.push({
      load_id: loadId,
      stop_type: s.t === 'pu' ? 'pickup' : 'delivery',
      seq: s.t === 'pu' ? ++pu : ++del,
      facility: String(s.name ?? '').trim(),
      address: String(s.loc ?? '').trim(),
      stop_time: iso(s),
      reference: String(s.po ?? '').trim(),
    })
  }
}
console.log('stop rows to insert:', rows.length)
let inserted = 0
for (let i = 0; i < rows.length; i += 400) {
  const { error } = await sb.from('load_stops').insert(rows.slice(i, i + 400))
  if (error) { console.error('chunk failed at', i, error.message); process.exit(1) }
  inserted += Math.min(400, rows.length - i)
}
console.log('inserted:', inserted)

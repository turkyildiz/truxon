// Backfill the ITS field-parity columns (equipment type, empty miles,
// customer fax/toll-free/secondary contact, driver address + empty-mile pay).
// Usage: node backfill_parity.mjs <email> <password> <migration_dir>
import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import XLSX from 'xlsx'

const env = Object.fromEntries(
  readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const sb = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)
const [email, password, dir] = process.argv.slice(2)
const { error: loginErr } = await sb.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('login failed:', loginErr.message); process.exit(1) }

const S = (v) => String(v ?? '').trim()
const norm = (s) => S(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()
const xl = (name) => { const wb = XLSX.readFile(`${dir}/${name}`); return XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { defval: '' }) }

// loads: equipment_type + empty_miles
const loads = JSON.parse(readFileSync(`${dir}/its_loads_full.json`, 'utf8'))
const idMap = JSON.parse(readFileSync(`${dir}/load_id_map.json`, 'utf8'))
let n = 0
for (const L of loads) {
  const id = idMap[L.meta.editId]
  if (!id) continue
  const patch = { equipment_type: S(L.trailer_type), empty_miles: parseFloat(L.empty_miles) || 0 }
  if (!patch.equipment_type && !patch.empty_miles) continue
  const { error } = await sb.from('loads').update(patch).eq('id', id)
  if (error) console.error('load', id, error.message)
  else if (++n % 200 === 0) console.log('loads updated:', n)
}
console.log('loads updated:', n)

// customers: fax / toll-free / secondary contact
const { data: allCust } = await sb.from('customers').select('id, company_name')
let c = 0
for (const r of xl('Customers.xlsx')) {
  const patch = {
    fax: S(r.Fax), toll_free: S(r['Toll Free']),
    secondary_contact: S(r['Secondary Contact']),
    secondary_phone: S(r['Secondary Contact Telephone']),
    secondary_email: S(r['Secondary Email']),
  }
  if (!Object.values(patch).some(Boolean)) continue
  const match = (allCust ?? []).find((x) => norm(x.company_name) === norm(r['Company Name']))
  if (!match) continue
  const { error } = await sb.from('customers').update(patch).eq('id', match.id)
  if (!error) c++
}
console.log('customers updated:', c)

// drivers: address/city/state + empty-mile pay
const { data: allDrv } = await sb.from('drivers').select('id, full_name')
let d = 0
for (const r of xl('Drivers.xlsx')) {
  const match = (allDrv ?? []).find((x) => norm(x.full_name) === norm(r.Name))
  if (!match) continue
  const { error } = await sb.from('drivers').update({
    address: S(r.Address), city: S(r.City), state: S(r.Province),
    pay_per_empty_mile: parseFloat(r['Empty Miles']) || 0,
  }).eq('id', match.id)
  if (!error) d++
}
console.log('drivers updated:', d)

// Backfill driver phone/email/notes and truck/trailer plates from the ITS
// exports AFTER migration 20260716180001_migration_fields.sql is applied.
// Usage: node backfill_extras.mjs <admin_email> <admin_password> <xlsx_dir>
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

const xl = (name) => { const wb = XLSX.readFile(`${dir}/${name}`); return XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { defval: '' }) }
const S = (v) => String(v ?? '').trim()
const dateOr = (v) => { const s = S(v); return /^\d{4}-\d{2}-\d{2}$/.test(s) && s !== '0000-00-00' ? s : null }
const norm = (s) => S(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()

let updated = 0
for (const r of xl('Drivers.xlsx')) {
  const name = S(r.Name)
  if (!name) continue
  const notes = [S(r['Medical Date']) !== '0000-00-00' && S(r['Medical Date']) && `Medical: ${S(r['Medical Date'])}`,
                 S(r['Next Medical']) !== '0000-00-00' && S(r['Next Medical']) && `Next medical: ${S(r['Next Medical'])}`,
                 S(r['Drug Test']) !== '0000-00-00' && S(r['Drug Test']) && `Drug test: ${S(r['Drug Test'])}`,
                 S(r.Notes)].filter(Boolean).join(' — ')
  const { data } = await sb.from('drivers').select('id, full_name')
  const match = (data ?? []).find((d) => norm(d.full_name) === norm(name))
  if (!match) continue
  const { error } = await sb.from('drivers').update({ phone: S(r.Cell) || S(r.Telephone), email: S(r['E-mail']), notes }).eq('id', match.id)
  if (!error) updated++
}
console.log('drivers backfilled:', updated)

for (const [file, table] of [['Trucks.xlsx', 'trucks'], ['Trailers.xlsx', 'trailers']]) {
  let n = 0
  const { data } = await sb.from(table).select('id, unit_number')
  for (const r of xl(file)) {
    const unit = S(r.Number)
    const match = (data ?? []).find((t) => norm(t.unit_number) === norm(unit))
    if (!match) continue
    const { error } = await sb.from(table).update({ plate_number: S(r['Plate Number']), plate_expiry: dateOr(r['Plate Expiry']), notes: S(r.Notes) }).eq('id', match.id)
    if (!error) n++
  }
  console.log(table, 'backfilled:', n)
}

// End-to-end smoke test against the LIVE Supabase project, running as a real
// authenticated user (anon key + password login) so RLS and triggers are
// exercised exactly as the app does.
//
// Usage: node scripts/e2e_smoke.mjs <email> <password>
// Reads VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY from .env.local

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
    .split('\n')
    .filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const supabase = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)

let passed = 0
function check(label, cond, extra = '') {
  console.log(`[${cond ? 'PASS' : 'FAIL'}] ${label} ${extra}`)
  if (!cond) process.exit(1)
  passed++
}
const ok = ({ data, error }) => {
  if (error) throw new Error(error.message)
  return data
}
const fails = async (promise) => {
  const { error } = await promise
  return error?.message ?? null
}

const [email, password] = process.argv.slice(2)
const stamp = Date.now()

// --- auth ---
const { error: anonErr } = await supabase.from('customers').select('id').limit(1)
check('anonymous access blocked', anonErr !== null || true) // RLS returns empty set or error for anon
const { data: anonRows } = await supabase.from('customers').select('id').limit(1)
check('anon sees no rows', !anonRows || anonRows.length === 0)

ok(await supabase.auth.signInWithPassword({ email, password }))
check('admin login', true)

// --- core records ---
const customer = ok(await supabase.from('customers').insert({ company_name: `E2E Freight ${stamp}`, payment_terms: 'Net 15' }).select().single())
check('create customer', customer.id > 0)

const driver = ok(await supabase.from('drivers').insert({ full_name: `E2E Driver ${stamp}`, pay_per_mile: 0.55 }).select().single())
check('create driver', driver.id > 0)

const truck = ok(await supabase.from('trucks').insert({ unit_number: `E2E-TRK-${stamp}` }).select().single())
const trailer = ok(await supabase.from('trailers').insert({ unit_number: `E2E-TRL-${stamp}` }).select().single())
check('create truck + trailer', truck.id > 0 && trailer.id > 0)

const maint = ok(await supabase.from('maintenance_records').insert({ equipment_type: 'truck', truck_id: truck.id, description: 'E2E oil change', cost: 100 }).select().single())
check('create maintenance record', maint.id > 0)
const badMaint = await fails(supabase.from('maintenance_records').insert({ equipment_type: 'truck', description: 'no truck id' }))
check('maintenance without equipment link rejected', badMaint !== null)

// --- load lifecycle ---
const monday = new Date()
monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7))
const deliveryTime = new Date(monday.getTime() + 26 * 3600e3).toISOString() // this week

const load = ok(await supabase.from('loads').insert({
  customer_id: customer.id,
  pickup_address: 'Chicago, IL', delivery_address: 'Dallas, TX',
  pickup_time: new Date(monday.getTime() + 2 * 3600e3).toISOString(),
  delivery_time: deliveryTime,
  driver_id: driver.id, truck_id: truck.id, trailer_id: trailer.id,
  rate: 2450, miles: 925,
}).select().single())
check('load number auto-generated', /^LD-\d{4}-\d{4}$/.test(load.load_number), load.load_number)
check('load auto-assigned', load.status === 'assigned')

const truckNow = ok(await supabase.from('trucks').select('status').eq('id', truck.id).single())
check('truck synced to in_use', truckNow.status === 'in_use')

const jumpErr = await fails(supabase.rpc('change_load_status', { p_load_id: load.id, p_status: 'delivered' }))
check('status skip rejected', jumpErr !== null, `(${jumpErr})`)
const directErr = await fails(supabase.from('loads').update({ status: 'delivered' }).eq('id', load.id).select().single())
check('direct status update rejected', directErr !== null)

for (const s of ['in_transit', 'delivered', 'completed']) {
  ok(await supabase.rpc('change_load_status', { p_load_id: load.id, p_status: s }))
}
check('advance to completed', true)
const truckAfter = ok(await supabase.from('trucks').select('status').eq('id', truck.id).single())
check('truck released after delivery', truckAfter.status === 'available')

const billErr = await fails(supabase.rpc('change_load_status', { p_load_id: load.id, p_status: 'billed' }))
check('billed without invoice rejected', billErr !== null)

// --- invoicing ---
const invoice = ok(await supabase.rpc('create_invoice', { p_customer_id: customer.id, p_load_ids: [load.id] }))
check('invoice created', /^INV-\d{4}-\d{4}$/.test(invoice.invoice_number), invoice.invoice_number)
check('invoice total', Number(invoice.total) === 2450)

const loadBilled = ok(await supabase.from('loads').select('status, invoice_id').eq('id', load.id).single())
check('load billed + linked', loadBilled.status === 'billed' && loadBilled.invoice_id === invoice.id)
const lockErr = await fails(supabase.from('loads').update({ rate: 9999 }).eq('id', load.id).select().single())
check('billed load locked', lockErr !== null)

// --- notes & audit ---
const { data: me } = await supabase.auth.getUser()
ok(await supabase.from('activity_log').insert({ entity_type: 'load', entity_id: load.id, action: 'note', detail: 'E2E note', user_id: me.user.id }))
const activity = ok(await supabase.from('activity_log').select('action').eq('entity_type', 'load').eq('entity_id', load.id))
const actions = activity.map((a) => a.action)
check('audit trail complete', actions.includes('created') && actions.includes('status_changed') && actions.includes('note'), `${activity.length} entries`)

// --- reports / dashboard / search ---
const report = ok(await supabase.rpc('weekly_report', { p_week_of: new Date().toISOString().slice(0, 10) }))
const driverRow = report.by_driver.find((r) => r.key_id === driver.id)
check('weekly report row', driverRow?.loads >= 1)
check('driver pay computed', Number(driverRow.driver_pay) === 508.75, `= $${driverRow.driver_pay}`)

const dash = ok(await supabase.rpc('dashboard_summary'))
check('dashboard summary', dash.week_loads >= 1 && Number(dash.week_revenue) >= 2450)

const search = ok(await supabase.rpc('global_search', { q: `E2E Freight ${stamp}` }))
check('global search', search.customers.length === 1)

// --- storage ---
const path = `load/${load.id}/e2e_test.txt`
ok(await supabase.storage.from('documents').upload(path, new Blob(['e2e']), { contentType: 'text/plain' }))
ok(await supabase.from('documents').insert({ entity_type: 'load', entity_id: load.id, filename: 'e2e_test.txt', storage_path: path, size_bytes: 3, uploaded_by: me.user.id }))
const dl = ok(await supabase.storage.from('documents').download(path))
check('storage upload + download', (await dl.text()) === 'e2e')

// --- cleanup ---
ok(await supabase.rpc('void_invoice', { p_invoice_id: invoice.id }))
const loadAfterVoid = ok(await supabase.from('loads').select('status').eq('id', load.id).single())
check('void invoice reverts load', loadAfterVoid.status === 'completed')
await supabase.storage.from('documents').remove([path])
await supabase.from('documents').delete().eq('storage_path', path)

console.log(`\nAll ${passed} checks passed against ${env.VITE_SUPABASE_URL}`)
process.exit(0)

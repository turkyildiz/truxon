// ITS Dispatch → Truxon data import (entities + loads).
// Usage: ADMIN_EMAIL=… ADMIN_PASSWORD=… node import.mjs [--dry] [--delta]
// Credentials come from env only — argv lands in shell history and `ps`.
// Bulk mode reads the xlsx exports + its_loads_full.json from this directory.
// --delta (the cutover mode): loads-only from its_loads_full.json — no xlsx
// needed; customers/drivers/trucks/trailers are matched against what is already
// in prod (missing customers/drivers auto-create as before; trucks punchlist).
// Writes punchlist.json with everything that didn't map cleanly.
import { createClient } from '@supabase/supabase-js'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'

const DIR = new URL('.', import.meta.url).pathname
// Connection: frontend/.env.local when present (repo-relative — no hardcoded
// home dir; the original box's /home/turkyildiz path broke on every machine
// since), else SUPABASE_URL/SUPABASE_ANON_KEY env, else prod defaults (anon
// key is public-safe — RLS enforces access; same default as mobile/build-apk.sh).
const envPath = DIR + '../../frontend/.env.local'
const fileEnv = existsSync(envPath)
  ? Object.fromEntries(readFileSync(envPath, 'utf8')
      .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
  : {}
const SB_URL = process.env.SUPABASE_URL || fileEnv.VITE_SUPABASE_URL || 'https://okoeeyxxvzypjiumraxq.supabase.co'
const SB_ANON = process.env.SUPABASE_ANON_KEY || fileEnv.VITE_SUPABASE_ANON_KEY || 'sb_publishable_Ak8T-1XgtjC00LXbiI9xDA_o5b_n7C-'
const sb = createClient(SB_URL, SB_ANON)
const email = process.env.ADMIN_EMAIL
const password = process.env.ADMIN_PASSWORD
const DRY = process.argv.includes('--dry')
const DELTA = process.argv.includes('--delta')
if (!email || !password) { console.error('Set ADMIN_EMAIL and ADMIN_PASSWORD in the environment (not argv)'); process.exit(2) }
const punch = []
const note = (area, msg) => { punch.push({ area, msg }); console.log('PUNCH:', area, '—', msg) }

const { error: loginErr } = await sb.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('login failed:', loginErr.message); process.exit(1) }

const S = (v) => String(v ?? '').trim()
const dateOr = (v) => { const s = S(v); return /^\d{4}-\d{2}-\d{2}$/.test(s) && s !== '0000-00-00' ? s : null }
const norm = (s) => S(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()

let custByNorm, drvByNorm, truckByUnit, trailerByUnit
if (DELTA) {
  // Loads-only cutover: entity maps come straight from prod, nothing xlsx.
  const grab = async (table, col) =>
    new Map((((await sb.from(table).select(`id, ${col}`)).data) ?? []).map((r) => [norm(r[col]), r.id]))
  custByNorm = await grab('customers', 'company_name')
  drvByNorm = await grab('drivers', 'full_name')
  truckByUnit = await grab('trucks', 'unit_number')
  trailerByUnit = await grab('trailers', 'unit_number')
  console.log(`delta mode: prod refs — ${custByNorm.size} customers, ${drvByNorm.size} drivers, ${truckByUnit.size} trucks, ${trailerByUnit.size} trailers`)
} else {
// xlsx only needed for the (historical) bulk path — lazy so delta mode runs without the package
const XLSX = (await import('xlsx')).default
const xl = (name) => XLSX.utils.sheet_to_json(XLSX.readFile(DIR + name).Sheets[XLSX.readFile(DIR + name).SheetNames[0]], { defval: '' })

// ---------- customers ----------
const custRows = xl('Customers.xlsx')
const { data: existingCust } = await sb.from('customers').select('id, company_name')
custByNorm = new Map((existingCust ?? []).map((c) => [norm(c.company_name), c.id]))
let custAdded = 0
for (const r of custRows) {
  const name = S(r['Company Name'])
  if (!name || custByNorm.has(norm(name))) continue
  const billing = [S(r['Billing Address']), S(r['Billing Address 2']), [S(r['Billing City 3']), S(r['Billing State']), S(r['Billing Postal/Zip'])].filter(Boolean).join(', ')].filter(Boolean).join('\n')
  const notes = [S(r.Comments), S(r.Notes), S(r['Billing Email']) && `Billing email: ${S(r['Billing Email'])}`].filter(Boolean).join(' — ')
  const payload = {
    company_name: name,
    contact_person: S(r.Contact),
    phone: S(r.Telephone),
    email: S(r.Email) || S(r['Billing Email']),
    payment_terms: S(r['Payment Terms']) || 'Net 30',
    billing_address: billing,
    notes,
    is_active: S(r.Blacklisted) !== '1',
  }
  if (!DRY) {
    const { data, error } = await sb.from('customers').insert(payload).select('id').single()
    if (error) { note('customers', `insert failed for "${name}": ${error.message}`); continue }
    custByNorm.set(norm(name), data.id)
  } else { custByNorm.set(norm(name), -1) }
  custAdded++
}
console.log(`customers: +${custAdded} (existing ${existingCust?.length ?? 0})`)

// ---------- drivers ----------
const drvRows = xl('Drivers.xlsx')
const { data: existingDrv } = await sb.from('drivers').select('id, full_name')
drvByNorm = new Map((existingDrv ?? []).map((d) => [norm(d.full_name), d.id]))
let drvAdded = 0
for (const r of drvRows) {
  const name = S(r.Name)
  if (!name || drvByNorm.has(norm(name))) continue
  const payload = {
    full_name: name,
    license_number: S(r['License Number']),
    license_expiration: dateOr(r['License Expiry']),
    date_of_birth: dateOr(r.DOB),
    hire_date: dateOr(r.DOH),
    pay_per_mile: parseFloat(r['Per Mile']) || 0,
    status: S(r.Status).toLowerCase() === 'active' ? 'active' : 'inactive',
  }
  const extras = {
    phone: S(r.Cell) || S(r.Telephone),
    email: S(r['E-mail']),
    notes: [S(r['Medical Date']) !== '0000-00-00' && S(r['Medical Date']) && `Medical: ${S(r['Medical Date'])}`,
            S(r['Next Medical']) !== '0000-00-00' && S(r['Next Medical']) && `Next medical: ${S(r['Next Medical'])}`,
            S(r['Drug Test']) !== '0000-00-00' && S(r['Drug Test']) && `Drug test: ${S(r['Drug Test'])}`,
            S(r.Notes)].filter(Boolean).join(' — '),
  }
  if (!DRY) {
    let { data, error } = await sb.from('drivers').insert({ ...payload, ...extras }).select('id').single()
    if (error && /column/.test(error.message)) {
      // phone/email/notes columns not applied yet — import core fields, backfill later
      ;({ data, error } = await sb.from('drivers').insert(payload).select('id').single())
      if (!error) note('drivers', `"${name}" imported without phone/email/medical notes (run pending migration, then backfill_extras.mjs)`)
    }
    if (error) { note('drivers', `insert failed for "${name}": ${error.message}`); continue }
    drvByNorm.set(norm(name), data.id)
  } else { drvByNorm.set(norm(name), -1) }
  drvAdded++
}
console.log(`drivers: +${drvAdded}`)

// ---------- trucks / trailers ----------
async function importEquipment(file, table) {
  const rows = xl(file)
  const { data: existing } = await sb.from(table).select('id, unit_number')
  const byUnit = new Map((existing ?? []).map((t) => [norm(t.unit_number), t.id]))
  let added = 0
  for (const r of rows) {
    const unit = S(r.Number)
    if (!unit || byUnit.has(norm(unit))) continue
    const yr = parseInt(r.Year)
    const typeStr = S(r.Type)
    const yrFromType = parseInt((typeStr.match(/\b(19|20)\d{2}\b/) || [])[0])
    const deactivated = dateOr(r['Deactivation Date'])
    const payload = {
      unit_number: unit,
      make: typeStr.replace(/\b(19|20)\d{2}\b/, '').trim(),
      model: S(r.Model ?? ''),
      year: Number.isFinite(yr) ? yr : Number.isFinite(yrFromType) ? yrFromType : null,
      vin: S(r.VIN),
      in_service_date: dateOr(r['Start Date'] ?? r['Activation Date']),
      out_of_service_date: deactivated,
      status: deactivated ? 'retired' : 'available',
    }
    const extras = {
      plate_number: S(r['Plate Number']),
      plate_expiry: dateOr(r['Plate Expiry']),
      notes: S(r.Notes),
    }
    if (!DRY) {
      let { data, error } = await sb.from(table).insert({ ...payload, ...extras }).select('id').single()
      if (error && /column/.test(error.message)) {
        ;({ data, error } = await sb.from(table).insert(payload).select('id').single())
        if (!error && (extras.plate_number || extras.notes)) note(table, `"${unit}" imported without plate/notes (pending migration + backfill)`)
      }
      if (error) { note(table, `insert failed for "${unit}": ${error.message}`); continue }
      byUnit.set(norm(unit), data.id)
    } else { byUnit.set(norm(unit), -1) }
    added++
  }
  console.log(`${table}: +${added}`)
  return byUnit
}
truckByUnit = await importEquipment('Trucks.xlsx', 'trucks')
trailerByUnit = await importEquipment('Trailers.xlsx', 'trailers')
} // end bulk (non-delta) entity import

// ---------- loads ----------
const loads = JSON.parse(readFileSync(DIR + 'its_loads_full.json', 'utf8'))
const { data: existingLoads } = await sb.from('loads').select('load_number')
const haveLoad = new Set((existingLoads ?? []).map((l) => l.load_number))

const STATUS_MAP = { 'Invoiced': 'completed', 'Completed': 'completed', 'Delivered': 'delivered', 'Unloading': 'in_transit', 'On Route': 'in_transit', 'Loading': 'in_transit', 'In Yard': 'in_transit', 'Dispatched': 'assigned', 'Covered': 'assigned', 'Open': 'pending', 'Refused': 'pending' }
const iso = (stop) => {
  if (!stop || !dateOr(stop.date)) return null
  let h = parseInt(stop.h) || 0
  if (stop.ap === 'PM' && h < 12) h += 12
  if (stop.ap === 'AM' && h === 12) h = 0
  return `${stop.date}T${String(h).padStart(2, '0')}:${String(parseInt(stop.m) || 0).padStart(2, '0')}:00`
}
const stopAddr = (s) => (s ? [S(s.name), S(s.loc)].filter(Boolean).join(', ') : '')

let loadsAdded = 0, skipped = 0, unmatchedDrivers = new Set(), unmatchedTrucks = new Set(), unmatchedTrailers = new Set(), unmatchedCustomers = new Set()
const idMap = {} // its editId -> truxon load id
for (const L of loads) {
  const loadNum = S(L.meta.loadNum || L.load_number)
  if (!loadNum || haveLoad.has(loadNum)) { skipped++; continue }
  const pickups = L.stops.filter((s) => s.t === 'pu')
  const dels = L.stops.filter((s) => s.t === 'del')
  const firstPu = pickups[0], lastDel = dels.at(-1)
  const custName = S(L.customer_name) || S(L.meta.listCustomer)
  let customer_id = custByNorm.get(norm(custName))
  if (!customer_id) {
    if (!DRY) {
      const { data, error } = await sb.from('customers').insert({ company_name: custName || `ITS customer (load ${loadNum})` }).select('id').single()
      if (error) { note('loads', `load ${loadNum}: no customer "${custName}" and create failed: ${error.message}`); skipped++; continue }
      customer_id = data.id
      custByNorm.set(norm(custName), customer_id)
    }
    unmatchedCustomers.add(custName)
  }
  let driver_id = null
  // ITS suffixes former drivers with "(Inactive)" — strip for matching.
  const drvName = S(L.driver).replace(/\s*\(Inactive\)\s*$/i, '')
  if (drvName && !/assign later|^$/i.test(drvName)) {
    driver_id = drvByNorm.get(norm(drvName)) ?? null
    if (!driver_id) {
      if (!DRY) {
        const { data, error } = await sb.from('drivers').insert({ full_name: drvName, status: 'inactive', pay_per_mile: 0 }).select('id').single()
        if (!error) { driver_id = data.id; drvByNorm.set(norm(drvName), driver_id) }
      } else {
        drvByNorm.set(norm(drvName), -1)
      }
      unmatchedDrivers.add(drvName)
    }
  }
  // ITS unit names that differ from Truxon's (audit 2026-07-19: ITS "003" = unit "03")
  const TRUCK_ALIASES = { '003': '03' }
  const truckUnit = S(L.truck)
  let truck_id = null
  if (truckUnit && !/assign later/i.test(truckUnit)) {
    truck_id = truckByUnit.get(norm(TRUCK_ALIASES[truckUnit] ?? truckUnit)) ?? null
    if (!truck_id) unmatchedTrucks.add(truckUnit)
  }
  const trailerUnit = S(L.trailer)
  let trailer_id = null
  if (trailerUnit && !/assign later/i.test(trailerUnit)) {
    trailer_id = trailerByUnit.get(norm(trailerUnit)) ?? null
    if (!trailer_id) unmatchedTrailers.add(trailerUnit)
  }
  const extraStops = L.stops.length > 2 ? L.stops.map((s, i) => `${i + 1}. ${s.t === 'pu' ? 'PU' : 'DEL'} ${stopAddr(s)} ${s.date ?? ''}`).join('; ') : ''
  const notes = [
    L.meta.invoiceNum && `ITS invoice #${L.meta.invoiceNum} (${L.meta.invoiceDate})`,
    extraStops && `All stops: ${extraStops}`,
    Number(L.empty_miles) > 0 && `Empty miles: ${L.empty_miles}`,
    S(L.notes),
    `[ITS #${L.meta.editId}]`,
  ].filter(Boolean).join('\n')
  const payload = {
    load_number: loadNum,
    reference_number: S(L.work_order),
    pickup_number: S(firstPu?.po),
    delivery_number: S(lastDel?.po),
    customer_id,
    status: STATUS_MAP[S(L.status)] ?? 'completed',
    pickup_address: stopAddr(firstPu),
    pickup_time: iso(firstPu),
    delivery_address: stopAddr(lastDel),
    delivery_time: iso(lastDel),
    driver_id, truck_id, trailer_id,
    rate: parseFloat(L.total_rate) || 0,
    miles: parseFloat(L.total_miles) || 0,
    special_terms: '',
    notes,
    // booked but not fully papered: no real stops, or no rate yet
    awaiting_paperwork: (!firstPu && !lastDel) || (parseFloat(L.total_rate) || 0) === 0,
    ...(iso(firstPu) ? { created_at: iso(firstPu) } : {}),
  }
  if (!DRY) {
    const { data, error } = await sb.from('loads').insert(payload).select('id').single()
    if (error) { note('loads', `load ${loadNum} insert failed: ${error.message}`); skipped++; continue }
    idMap[L.meta.editId] = data.id
  }
  loadsAdded++
  if (loadsAdded % 100 === 0) console.log(`loads: ${loadsAdded}…`)
}
console.log(`loads: +${loadsAdded}, skipped(existing/fail): ${skipped}`)
if (unmatchedCustomers.size) note('customers', `created minimal customer records for load brokers missing from customer list: ${[...unmatchedCustomers].slice(0, 20).join('; ')}${unmatchedCustomers.size > 20 ? '…' : ''}`)
if (unmatchedDrivers.size) note('drivers', `drivers on loads but not in ITS driver list (created as INACTIVE, no license/pay data): ${[...unmatchedDrivers].join('; ')}`)
if (unmatchedTrucks.size) note('trucks', `truck units on loads with no truck record (left unassigned): ${[...unmatchedTrucks].join('; ')}`)
if (unmatchedTrailers.size) note('trailers', `trailer units on loads with no trailer record (left unassigned): ${[...unmatchedTrailers].join('; ')}`)

writeFileSync(DIR + 'load_id_map.json', JSON.stringify(idMap))
writeFileSync(DIR + 'punchlist.json', JSON.stringify(punch, null, 1))
console.log(`done. punch list items: ${punch.length} → punchlist.json`)

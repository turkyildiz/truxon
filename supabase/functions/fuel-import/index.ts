// Fuel-import — ingests an AtoB transactions CSV into public.fuel_transactions.
//
// Auth (either):
//   - FUEL_IMPORT_KEY in the X-Fuel-Key header — used by the scheduled NAS
//     fetcher, so it never needs the service-role key on the box; OR
//   - an admin JWT — used by a manual in-app "import CSV" action.
// Once authorized, the CSV is parsed here (money/card/date cleanup) and handed
// to the SECURITY DEFINER import_fuel_transactions() RPC as JSON, which upserts
// on AtoB's UUID (idempotent) and matches each row to a truck/driver.
//
// Body: raw CSV (Content-Type text/csv) or JSON { csv: "<text>" }.

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json } from '../_shared/auth.ts'

// AtoB header → our field. Unmapped columns are ignored but preserved in raw.
const FIELD: Record<string, string> = {
  'Transaction Date (GMT)': 'transaction_time',
  'Posted Date (GMT)': 'posted_date',
  'Status': 'status',
  'Card Last Four': 'card_last_four',
  'Merchant': 'merchant',
  'Amount': 'amount',
  'Net of Discount': 'net_of_discount',
  'Discount': 'discount',
  'Driver Name': 'driver_name',
  'Vehicle Name': 'vehicle_name',
  'VIN': 'vin',
  'Merchant City': 'merchant_city',
  'Merchant State': 'merchant_state',
  'Merchant Zip': 'merchant_zip',
  'Merchant Category': 'merchant_category',
  'Type': 'fuel_type',
  'Gallons': 'gallons',
  'Price Per Gallon': 'price_per_gallon',
  'Description': 'description',
  'Prompted Odometer': 'prompted_odometer',
  'Telematics Odometer': 'telematics_odometer',
  'Tag': 'tag',
  'UUID': 'uuid',
}
const MONEY = new Set(['amount', 'net_of_discount', 'discount', 'price_per_gallon'])
const NUM = new Set(['gallons'])
const INT = new Set(['prompted_odometer', 'telematics_odometer'])
const TS = new Set(['transaction_time', 'posted_date'])

/** RFC-4180-ish CSV split: handles quoted fields, embedded commas, "" escapes. */
function parseCsv(text: string): string[][] {
  const rows: string[][] = []
  let row: string[] = [], field = '', inQuotes = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (inQuotes) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++ } else inQuotes = false }
      else field += c
    } else if (c === '"') inQuotes = true
    else if (c === ',') { row.push(field); field = '' }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = '' }
    else if (c === '\r') { /* skip */ }
    else field += c
  }
  if (field.length || row.length) { row.push(field); rows.push(row) }
  return rows.filter((r) => r.length > 1 || (r.length === 1 && r[0] !== ''))
}

function money(v: string): number | null {
  const s = v.replace(/[$,\s]/g, '')
  if (!s) return null
  const n = Number(s)
  return Number.isFinite(n) ? n : null
}

/** "07/19/2026 12:19:25" (GMT) → ISO 8601 UTC. Empty → null. */
function gmtToIso(v: string): string | null {
  const m = v.trim().match(/^(\d{2})\/(\d{2})\/(\d{4})[ T](\d{2}):(\d{2}):(\d{2})$/)
  if (!m) return null
  const [, mo, d, y, h, mi, s] = m
  return `${y}-${mo}-${d}T${h}:${mi}:${s}Z`
}

function toRow(header: string[], cols: string[]): Record<string, unknown> | null {
  const raw: Record<string, string> = {}
  const out: Record<string, unknown> = {}
  header.forEach((h, i) => {
    const val = cols[i] ?? ''
    raw[h] = val
    const key = FIELD[h.trim()]
    if (!key) return
    if (key === 'card_last_four') out[key] = val.replace(/[^0-9]/g, '').slice(-4) || null
    else if (TS.has(key)) out[key] = gmtToIso(val)
    else if (MONEY.has(key)) out[key] = money(val)
    else if (NUM.has(key)) { const n = Number(val); out[key] = val && Number.isFinite(n) ? n : null }
    else if (INT.has(key)) { const n = parseInt(val, 10); out[key] = Number.isFinite(n) ? n : null }
    else out[key] = val
  })
  if (!out.uuid || !out.transaction_time) return null // skip malformed / total rows
  out.raw = raw
  return out
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  // --- auth: shared key (NAS fetcher) or admin JWT (manual import) ---
  const keyHeader = req.headers.get('X-Fuel-Key')
  const expectedKey = Deno.env.get('FUEL_IMPORT_KEY')
  let authorized = !!(expectedKey && keyHeader && keyHeader === expectedKey)
  if (!authorized) {
    const caller = await getCaller(req)
    if (caller instanceof Response) return caller
    if (caller.role !== 'admin') return json({ error: 'Admin or fuel key required' }, 403)
    authorized = true
  }

  // --- body: raw CSV or { csv } ---
  let csv: string
  const ct = req.headers.get('content-type') ?? ''
  if (ct.includes('application/json')) {
    const body = await req.json().catch(() => ({}))
    csv = String(body.csv ?? '')
  } else {
    csv = await req.text()
  }
  if (!csv.trim()) return json({ error: 'Empty CSV body' }, 422)

  const grid = parseCsv(csv)
  if (grid.length < 2) return json({ error: 'CSV has no data rows' }, 422)
  const header = grid[0]
  if (!header.some((h) => h.trim() === 'UUID')) return json({ error: 'CSV missing expected AtoB columns (no UUID)' }, 422)

  const rows = grid.slice(1).map((r) => toRow(header, r)).filter(Boolean)
  if (rows.length === 0) return json({ error: 'No valid rows parsed' }, 422)

  // Import via the SECURITY DEFINER RPC using the service role.
  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data, error } = await svc.rpc('import_fuel_transactions', { p_rows: rows })
  if (error) return json({ error: error.message }, 500)

  return json({ ok: true, parsed: rows.length, ...(data as object) })
})

/**
 * Data access layer — every Supabase query/RPC/storage/edge-function call
 * the app makes lives here, so pages stay free of query syntax.
 *
 * Table/RPC shapes come from the generated src/database.types.ts; the domain
 * types in types.ts stay the public interface for pages. json-returning RPCs
 * are typed as Json by codegen, so those keep a single cast at this boundary.
 */
import { supabase, unwrap } from './supabase'
import type { Tables, TablesInsert, TablesUpdate } from './database.types'
import type {
  Activity,
  Customer,
  DashboardSummary,
  DocumentMeta,
  Driver,
  Equipment,
  FuelByTruckRow,
  FuelIftaRow,
  FuelImportResult,
  Invoice,
  QboStatus,
  AcctSummary,
  AgingRow,
  UnbilledLoad,
  RevenueMonth,
  CustomerRevenue,
  MarginMonth,
  InvoicePayment,
  GlPnlMonth,
  GlExpenseRow,
  GlBreakevenMonth,
  CfoSnapshot,
  Load,
  LoadStatus,
  MaintenanceAlert,
  MaintenanceByTruckRow,
  MaintenanceByVendorRow,
  MaintenanceCpm,
  MaintenanceDueRow,
  MaintenanceRecord,
  MaintenanceSummary,
  MaintenanceVendor,
  FleetOdometerRow,
  PmProgram,
  Profile,
  SearchResults,
  TollByAgencyRow,
  TollByTruckRow,
  WeeklyReport,
} from './types'

/** Form-shaped payloads pages submit; cast to the generated Insert/Update
 * types at the query so the compiler checks the rest of the chain. */
type Row = Record<string, unknown>

/** Strip characters that break PostgREST filter grammar. */
export function sanitizeSearchTerm(q: string): string {
  return q
    .replace(/[%_\\]/g, '')
    .replace(/[,.()*"'\\]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80)
}

// ---------- Customers ----------

export async function listCustomers(q?: string, opts: { includeInactive?: boolean } = {}): Promise<Customer[]> {
  let query = supabase.from('customers').select('*').order('company_name')
  if (!opts.includeInactive) query = query.eq('is_active', true)
  const s = q ? sanitizeSearchTerm(q) : ''
  if (s) query = query.or(`company_name.ilike.%${s}%,contact_person.ilike.%${s}%`)
  return unwrap(await query)
}

export async function createCustomer(payload: Row): Promise<Customer> {
  return unwrap(await supabase.from('customers').insert(payload as TablesInsert<'customers'>).select().single())
}

export async function updateCustomer(id: number, payload: Row): Promise<Customer> {
  return unwrap(await supabase.from('customers').update(payload as TablesUpdate<'customers'>).eq('id', id).select().single())
}

/** Delete a customer — server-guarded: only succeeds if we've never hauled
 *  their cargo (no loads and no invoices). Rejects with a message otherwise. */
export async function deleteCustomer(id: number): Promise<void> {
  const { error } = await supabase.rpc('delete_customer', { p_id: id })
  if (error) throw error
}

export interface EnrichBatch {
  processed: number
  lastId: number
  filledTotal: number
  apply: boolean
  customers: Array<{ id: number; company_name: string; docsUsed: number; filled: number; proposed: string[]; skipped: string[] }>
}

const ENRICH_STOP = new Set(['inc', 'llc', 'ltd', 'co', 'corp', 'company', 'group', 'the', 'and', 'logistics', 'transport', 'transportation', 'freight', 'trucking', 'carriers', 'carrier', 'services', 'service', 'brokerage', 'solutions', 'usa'])
const enrichTokens = (s: string) => new Set(String(s ?? '').toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter((t) => t.length > 2 && !ENRICH_STOP.has(t)))

/** Customers still missing key contact fields (for the vision rate-con pass). */
export async function customersMissingInfo(): Promise<{ id: number; company_name: string }[]> {
  return unwrap(await supabase.from('customers').select('id, company_name').or('contact_person.eq.,phone.eq.,email.eq.').order('id'))
}

/** Vision-read a customer's loads' rate confirmations (scanned PDFs) in the
 *  browser and fill any still-blank fields. This is the 3rd source: it reads
 *  the image-only rate cons that text extraction and QBO can't cover. Slow
 *  (renders + vision AI per doc), so run it targeted, not on every refresh. */
export async function enrichCustomerFromRateCons(customerId: number, companyName: string): Promise<number> {
  const { data: loads } = await supabase.from('loads').select('id').eq('customer_id', customerId).limit(80)
  const loadIds = (loads ?? []).map((l) => l.id)
  if (!loadIds.length) return 0
  const { data: docs } = await supabase.from('documents')
    .select('id, storage_path, filename, content_type')
    .eq('entity_type', 'load').in('entity_id', loadIds)
    .order('uploaded_at', { ascending: false }).limit(4)
  const pdfs = (docs ?? []).filter((d) => /pdf/i.test(d.content_type) || /\.pdf$/i.test(d.filename))
  const merged: Record<string, unknown> = {}
  let sourceDocId: number | null = null
  const a = enrichTokens(companyName)
  for (const d of pdfs.slice(0, 2)) {
    const { data: blob } = await supabase.storage.from('documents').download(d.storage_path)
    if (!blob) continue
    const file = new File([blob], d.filename, { type: 'application/pdf' })
    let res = await extractCustomerPdf(file)
    if (res.error && /rate limit/i.test(res.error)) throw new Error('RATE_LIMIT')
    if (res.needs_images) {
      const { renderPdfPages } = await import('./pdfPages')
      const pages = await renderPdfPages(file)
      if (pages.length) res = await extractCustomerPdf(file, pages)
      if (res.error && /rate limit/i.test(res.error)) throw new Error('RATE_LIMIT')
    }
    const f = res.fields
    if (!f) continue
    // name-match guard: only trust a rate con whose broker matches this customer
    if (f.company_name) { const b = enrichTokens(f.company_name); if (![...b].some((t) => a.has(t))) continue }
    for (const k of ['contact_person', 'phone', 'email', 'billing_address'] as const) {
      if (f[k] && !merged[k]) { merged[k] = f[k]; if (sourceDocId == null) sourceDocId = d.id }
    }
    if (f.mc_number && !merged.mc_number) merged.mc_number = f.mc_number
    if (f.notes && !merged.notes) merged.notes = f.notes
  }
  if (Object.keys(merged).length === 0) return 0
  const { data, error } = await supabase.functions.invoke('customer-enrich', {
    body: { customer_id: customerId, fields: merged, source_document_id: sourceDocId },
  })
  if (error) throw error
  return (data as { filled?: number })?.filled ?? 0
}

/** Enrich blank customer fields from QuickBooks (structured contact/address).
 *  Fast, one shot; fills billing address / email / contact best. */
export async function enrichCustomersFromQbo(): Promise<{ matched: number; filledTotal: number; touched: number }> {
  const { data, error } = await supabase.functions.invoke('qbo-sync', { body: { mode: 'customers' } })
  if (error) throw error
  return data as { matched: number; filledTotal: number; touched: number }
}

/** One page of customer enrichment (admin only). The caller advances `afterId`
 *  with the returned `lastId` until `processed` is 0. */
export async function enrichCustomersBatch(afterId: number, apply: boolean): Promise<EnrichBatch> {
  // Small chunks: edge functions cap at ~150s and each doc is a download + LLM
  // call, so the UI pages through in bites of a few customers.
  const { data, error } = await supabase.functions.invoke('customer-enrich', {
    body: { after_id: afterId, apply, limit: 6, docs_per_customer: 2 },
  })
  if (error) throw error
  return data as EnrichBatch
}

// ---------- Drivers ----------

export async function listDrivers(q?: string): Promise<Driver[]> {
  let query = supabase.from('drivers').select('*').order('full_name')
  const s = q ? sanitizeSearchTerm(q) : ''
  if (s) query = query.ilike('full_name', `%${s}%`)
  return unwrap(await query)
}

/** Driver-role profiles available to link (or the currently linked one). */
export async function listLinkableDriverProfiles(currentUserId?: string | null): Promise<Profile[]> {
  const { data: profiles, error } = await supabase
    .from('profiles')
    .select('id, username, full_name, role, is_active')
    .eq('role', 'driver')
    .eq('is_active', true)
    .order('username')
  if (error) throw error
  const drivers = await listDrivers()
  const taken = new Set(drivers.map((d) => d.user_id).filter((id): id is string => Boolean(id)))
  return (profiles ?? []).filter((p) => !taken.has(p.id) || p.id === currentUserId)
}

export interface FleetPin {
  driver_id: number
  driver_name: string
  truck_id: number | null
  truck_unit: string | null
  load_id: number | null
  load_number: string | null
  lat: number
  lng: number
  speed_mps: number | null
  heading_deg: number | null
  recorded_at: string
  // ELD-sourced extras (present when source === 'eld')
  source?: 'eld' | 'mobile'
  location?: string | null
  odometer?: number | null
  hos_drive_sec?: number | null
  duty_status?: string | null
  eld_status?: string | null
}

export async function fleetPositionsSnapshot(): Promise<FleetPin[]> {
  const data = unwrap(await supabase.rpc('fleet_positions_snapshot'))
  return (data as unknown as FleetPin[]) ?? []
}

/** Recent breadcrumb trail for one driver (staff-readable via vehicle_positions RLS). */
export async function driverTrail(driverId: number): Promise<{ lat: number; lng: number }[]> {
  const data = unwrap(
    await supabase
      .from('vehicle_positions')
      .select('lat, lng, recorded_at')
      .eq('driver_id', driverId)
      .order('recorded_at', { ascending: false })
      .limit(60),
  )
  return (data ?? []).map((p) => ({ lat: p.lat, lng: p.lng })).reverse()
}

export async function createDriver(payload: Row): Promise<Driver> {
  return unwrap(await supabase.from('drivers').insert(payload as TablesInsert<'drivers'>).select().single())
}

export async function updateDriver(id: number, payload: Row): Promise<Driver> {
  return unwrap(await supabase.from('drivers').update(payload as TablesUpdate<'drivers'>).eq('id', id).select().single())
}

// ---------- Trucks / Trailers ----------

function equipmentApi(table: 'trucks' | 'trailers') {
  return {
    async list(q?: string): Promise<Equipment[]> {
      let query = supabase.from(table).select('*').order('unit_number')
      if (q) query = query.ilike('unit_number', `%${q}%`)
      return unwrap(await query)
    },
    async create(payload: Row): Promise<Equipment> {
      return unwrap(await supabase.from(table).insert(payload as TablesInsert<'trucks'>).select().single())
    },
    async update(id: number, payload: Row): Promise<Equipment> {
      return unwrap(await supabase.from(table).update(payload as TablesUpdate<'trucks'>).eq('id', id).select().single())
    },
  }
}

export const trucksApi = equipmentApi('trucks')
export const trailersApi = equipmentApi('trailers')

// ---------- Maintenance ----------

const MAINTENANCE_SELECT = '*, truck:trucks(unit_number), trailer:trailers(unit_number)'

type MaintenanceRow = Tables<'maintenance_records'> & {
  truck: Pick<Tables<'trucks'>, 'unit_number'> | null
  trailer: Pick<Tables<'trailers'>, 'unit_number'> | null
}

function mapMaintenance({ truck, trailer, ...row }: MaintenanceRow): MaintenanceRecord {
  // `source` is a text+check column (codegen types it as string); cast the
  // mapped row to the domain union at this boundary.
  return {
    ...row,
    equipment_unit: row.equipment_type === 'truck' ? truck?.unit_number ?? null : trailer?.unit_number ?? null,
  } as MaintenanceRecord
}

export async function listMaintenance(): Promise<MaintenanceRecord[]> {
  const rows = unwrap(
    await supabase.from('maintenance_records').select(MAINTENANCE_SELECT).order('date_completed', { ascending: false, nullsFirst: false }),
  )
  return rows.map(mapMaintenance)
}

export async function createMaintenance(payload: Row): Promise<MaintenanceRecord> {
  return mapMaintenance(
    unwrap(await supabase.from('maintenance_records').insert(payload as TablesInsert<'maintenance_records'>).select(MAINTENANCE_SELECT).single()),
  )
}

export async function updateMaintenance(id: number, payload: Row): Promise<MaintenanceRecord> {
  return mapMaintenance(
    unwrap(await supabase.from('maintenance_records').update(payload as TablesUpdate<'maintenance_records'>).eq('id', id).select(MAINTENANCE_SELECT).single()),
  )
}

// ---------- Maintenance: vendors & PM programs ----------

export const vendorsApi = {
  async list(): Promise<MaintenanceVendor[]> {
    return unwrap(await supabase.from('maintenance_vendors').select('*').order('name'))
  },
  async create(payload: Row): Promise<MaintenanceVendor> {
    return unwrap(await supabase.from('maintenance_vendors').insert(payload as TablesInsert<'maintenance_vendors'>).select().single())
  },
  async update(id: number, payload: Row): Promise<MaintenanceVendor> {
    return unwrap(await supabase.from('maintenance_vendors').update(payload as TablesUpdate<'maintenance_vendors'>).eq('id', id).select().single())
  },
}

export const pmProgramsApi = {
  // applies_to is a text+check column (codegen types it as string), so cast to
  // the PmProgram union at this boundary — same pattern as the RPC wrappers.
  async list(): Promise<PmProgram[]> {
    return unwrap(await supabase.from('pm_programs').select('*').order('name')) as unknown as PmProgram[]
  },
  async create(payload: Row): Promise<PmProgram> {
    return unwrap(await supabase.from('pm_programs').insert(payload as TablesInsert<'pm_programs'>).select().single()) as unknown as PmProgram
  },
  async update(id: number, payload: Row): Promise<PmProgram> {
    return unwrap(await supabase.from('pm_programs').update(payload as TablesUpdate<'pm_programs'>).eq('id', id).select().single()) as unknown as PmProgram
  },
}

// ---------- Maintenance: engine & analytics (RPCs) ----------

/** Unified "needs attention" feed: PM/inspection due + plate expiry + stale WOs. */
export async function maintenanceAlerts(): Promise<MaintenanceAlert[]> {
  const data = unwrap(await supabase.rpc('maintenance_alerts'))
  return (data as unknown as MaintenanceAlert[]) ?? []
}

/** Per-unit PM/inspection status board (miles/days remaining, due_status). */
export async function maintenanceDue(): Promise<MaintenanceDueRow[]> {
  const data = unwrap(await supabase.rpc('maintenance_due'))
  return (data as unknown as MaintenanceDueRow[]) ?? []
}

/** Current odometer per truck from the fuel-card readings, with reading date. */
export async function fleetOdometers(): Promise<FleetOdometerRow[]> {
  const data = unwrap(await supabase.rpc('fleet_odometers'))
  return (data as unknown as FleetOdometerRow[]) ?? []
}

/** Command-center rollup: spend split, PM compliance, deadlined %, top units. */
export async function maintenanceSummary(start: string, end: string): Promise<MaintenanceSummary> {
  return unwrap(await supabase.rpc('maintenance_summary', { p_start: start, p_end: end })) as unknown as MaintenanceSummary
}

/** Fleet Maintenance CPM & Tire CPM over the range (playbook #29/#31). */
export async function maintenanceCpm(start: string, end: string): Promise<MaintenanceCpm> {
  return unwrap(await supabase.rpc('maintenance_cpm', { p_start: start, p_end: end })) as unknown as MaintenanceCpm
}

/** Maintenance cost + CPM per truck over the range (server sorts by cost desc). */
export async function maintenanceByTruck(start: string, end: string): Promise<MaintenanceByTruckRow[]> {
  const data = unwrap(await supabase.rpc('maintenance_by_truck', { p_start: start, p_end: end }))
  return (data as unknown as MaintenanceByTruckRow[]) ?? []
}

/** Maintenance spend per shop/vendor over the range. */
export async function maintenanceByVendor(start: string, end: string): Promise<MaintenanceByVendorRow[]> {
  const data = unwrap(await supabase.rpc('maintenance_by_vendor', { p_start: start, p_end: end }))
  return (data as unknown as MaintenanceByVendorRow[]) ?? []
}

// ---------- Loads ----------

const LOAD_SELECT =
  '*, customer:customers(company_name), driver:drivers(full_name), truck:trucks(unit_number), trailer:trailers(unit_number)'

type LoadRow = Tables<'loads'> & {
  customer: Pick<Tables<'customers'>, 'company_name'> | null
  driver: Pick<Tables<'drivers'>, 'full_name'> | null
  truck: Pick<Tables<'trucks'>, 'unit_number'> | null
  trailer: Pick<Tables<'trailers'>, 'unit_number'> | null
}

function mapLoad({ customer, driver, truck, trailer, ...load }: LoadRow): Load {
  return {
    ...load,
    customer_name: customer?.company_name ?? null,
    driver_name: driver?.full_name ?? null,
    truck_unit: truck?.unit_number ?? null,
    trailer_unit: trailer?.unit_number ?? null,
    rate_per_mile: load.miles > 0 ? Math.round((load.rate / load.miles) * 100) / 100 : null,
  }
}

export interface LoadFilters {
  q?: string
  status?: string
  statuses?: string[]
  awaiting_paperwork?: boolean
  customer_id?: string | number
  driver_id?: string | number
  date_from?: string
  date_to?: string
}

// ---------- Missing-POD detection ----------

export interface MissingPodRow {
  load_id: number
  load_number: string
  customer: string | null
  status: string
  delivered_at: string | null
  reference_number: string
  pickup_number: string
  delivery_number: string
}

/** Delivered/billed loads with no proof-of-delivery on file (admin/dispatcher/accountant). */
export async function listMissingPods(days = 45): Promise<MissingPodRow[]> {
  const { data, error } = await supabase.rpc('loads_missing_pod', { p_days: days })
  if (error) throw error
  return (data ?? []) as unknown as MissingPodRow[]
}

// ---------- Trux dispatch shadow (observe-only ledger) ----------

export interface TruxObservation {
  id: number
  received_at: string | null
  sender_email: string
  sender_name: string
  subject: string
  classification: string
  summary: string
  extracted: { broker?: string | null; ref?: string | null; amount?: number | null } | null
  would_action: string
  would_detail: string
  confidence: string
  matched_customer_id: number | null
  matched_load_id: number | null
  reviewed: boolean
  review_note: string
  created_at: string
}

export async function listObservations(opts: { classification?: string; unreviewedOnly?: boolean; limit?: number } = {}): Promise<TruxObservation[]> {
  let q = supabase.from('trux_observations').select('*').order('received_at', { ascending: false }).limit(opts.limit ?? 100)
  if (opts.classification) q = q.eq('classification', opts.classification)
  if (opts.unreviewedOnly) q = q.eq('reviewed', false)
  const rows = unwrap(await q)
  return rows as unknown as TruxObservation[]
}

export async function markObservationReviewed(id: number, reviewed: boolean): Promise<void> {
  const { error } = await supabase.from('trux_observations').update({ reviewed }).eq('id', id)
  if (error) throw error
}

/** Flag/clear "awaiting final paperwork" on a load (admin/dispatcher). */
export async function setLoadPaperwork(id: number, awaiting: boolean): Promise<void> {
  const { error } = await supabase.rpc('set_load_paperwork', { p_id: id, p_awaiting: awaiting })
  if (error) throw error
}

export async function listLoads(filters: LoadFilters = {}): Promise<Load[]> {
  let query = supabase.from('loads').select(LOAD_SELECT).order('created_at', { ascending: false }).limit(200)
  if (filters.status) query = query.eq('status', filters.status as Tables<'loads'>['status'])
  if (filters.statuses?.length) query = query.in('status', filters.statuses as Tables<'loads'>['status'][])
  if (filters.awaiting_paperwork) query = query.eq('awaiting_paperwork', true)
  if (filters.customer_id) query = query.eq('customer_id', Number(filters.customer_id))
  if (filters.driver_id) query = query.eq('driver_id', Number(filters.driver_id))
  if (filters.date_from) query = query.gte('pickup_time', filters.date_from)
  if (filters.date_to) query = query.lte('pickup_time', filters.date_to + 'T23:59:59')
  if (filters.q) {
    const s = sanitizeSearchTerm(filters.q)
    if (s) {
      query = query.or(
        `load_number.ilike.%${s}%,reference_number.ilike.%${s}%,pickup_address.ilike.%${s}%,delivery_address.ilike.%${s}%`,
      )
    }
  }
  const rows = unwrap(await query)
  return rows.map(mapLoad)
}

export async function getLoad(id: number | string): Promise<Load> {
  return mapLoad(unwrap(await supabase.from('loads').select(LOAD_SELECT).eq('id', Number(id)).single()))
}

// ---------- Load stops (multi-stop itinerary) ----------

export interface LoadStop {
  id?: number
  load_id?: number
  stop_type: 'pickup' | 'delivery'
  seq: number
  facility: string
  address: string
  stop_time: string | null
  reference: string
}

export async function listStops(loadId: number | string): Promise<LoadStop[]> {
  const rows = unwrap(
    await supabase.from('load_stops').select('*').eq('load_id', Number(loadId)).order('stop_type', { ascending: false }).order('seq'),
  )
  // stop_type is plain text in the schema; the app only ever writes these two values.
  return rows.map((s) => ({ ...s, stop_type: s.stop_type as LoadStop['stop_type'] }))
}

/** Replace a load's full itinerary — one transactional RPC (seq renumbered
 * server-side), so a failure can't leave the load with half an itinerary. */
export async function replaceStops(loadId: number | string, stops: Omit<LoadStop, 'id' | 'load_id' | 'seq'>[]): Promise<void> {
  unwrap(await supabase.rpc('replace_load_stops', { p_load_id: Number(loadId), p_stops: stops }))
}

export async function createLoad(payload: Row, stops: Omit<LoadStop, 'id' | 'load_id' | 'seq'>[] = []): Promise<Load> {
  const load = mapLoad(unwrap(await supabase.from('loads').insert(payload as TablesInsert<'loads'>).select(LOAD_SELECT).single()))
  if (stops.length > 0) await replaceStops(load.id, stops)
  return load
}

export async function updateLoad(id: number | string, payload: Row): Promise<Load> {
  const load = mapLoad(
    unwrap(await supabase.from('loads').update(payload as TablesUpdate<'loads'>).eq('id', Number(id)).select(LOAD_SELECT).single()),
  )
  if (payload.driver_id != null) {
    void supabase.functions
      .invoke('notify', {
        body: { action: 'notify_load', load_id: Number(id), type: 'assignment', title: 'New load assignment', body: load.load_number },
      })
      .catch(() => {})
  }
  return load
}

export async function changeLoadStatus(id: number | string, status: LoadStatus): Promise<void> {
  // change_load_status only walks the linear workflow; 'cancelled' goes
  // through cancelLoad/uncancelLoad (the RPC rejects it server-side too).
  unwrap(await supabase.rpc('change_load_status', { p_load_id: Number(id), p_status: status }))
}

export async function cancelLoad(id: number | string, reason = ''): Promise<void> {
  unwrap(await supabase.rpc('cancel_load', { p_load_id: Number(id), p_reason: reason }))
}

export async function uncancelLoad(id: number | string): Promise<void> {
  unwrap(await supabase.rpc('uncancel_load', { p_load_id: Number(id) }))
}

// ---------- Invoices ----------

const INVOICE_SELECT = '*, customer:customers(company_name), loads(id)'

type InvoiceRow = Tables<'invoices'> & {
  customer: Pick<Tables<'customers'>, 'company_name'> | null
  loads: { id: number }[]
}

function mapInvoice({ customer, loads, ...invoice }: InvoiceRow): Invoice {
  return {
    ...invoice,
    source: invoice.source as Invoice['source'],
    customer_name: customer?.company_name ?? null,
    load_count: loads.length,
  }
}

export async function listInvoices(): Promise<Invoice[]> {
  const rows = unwrap(await supabase.from('invoices').select(INVOICE_SELECT).order('created_at', { ascending: false }))
  return rows.map(mapInvoice)
}

export async function createInvoice(customerId: number, loadIds: number[]): Promise<Invoice> {
  const invoice = unwrap(await supabase.rpc('create_invoice', { p_customer_id: customerId, p_load_ids: loadIds }))
  return { ...invoice, source: invoice.source as Invoice['source'], customer_name: null, load_count: loadIds.length }
}

export async function setInvoiceStatus(id: number, status: string): Promise<void> {
  unwrap(await supabase.rpc('set_invoice_status', { p_invoice_id: id, p_status: status as Invoice['status'] }))
}

export async function voidInvoice(id: number): Promise<void> {
  unwrap(await supabase.rpc('void_invoice', { p_invoice_id: id }))
}

// ── Accounting module ───────────────────────────────────────────────────────

export async function acctSummary(): Promise<AcctSummary> {
  return unwrap(await supabase.rpc('acct_summary')) as unknown as AcctSummary
}

export async function acctAging(): Promise<AgingRow[]> {
  return unwrap(await supabase.rpc('acct_aging')) as unknown as AgingRow[]
}

export async function acctUnbilledLoads(): Promise<UnbilledLoad[]> {
  return unwrap(await supabase.rpc('acct_unbilled_loads')) as unknown as UnbilledLoad[]
}

export async function acctRevenueMonthly(months = 12): Promise<RevenueMonth[]> {
  return unwrap(await supabase.rpc('acct_revenue_monthly', { p_months: months })) as unknown as RevenueMonth[]
}

export async function acctRevenueByCustomer(days = 365): Promise<CustomerRevenue[]> {
  return unwrap(await supabase.rpc('acct_revenue_by_customer', { p_days: days })) as unknown as CustomerRevenue[]
}

export async function acctMarginMonthly(months = 12): Promise<MarginMonth[]> {
  return unwrap(await supabase.rpc('acct_margin_monthly', { p_months: months })) as unknown as MarginMonth[]
}

export async function recordInvoicePayment(
  invoiceId: number,
  amount: number,
  method: string,
  reference?: string,
  receivedAt?: string,
  notes?: string,
): Promise<{ balance: number; paid: boolean }> {
  return unwrap(await supabase.rpc('record_invoice_payment', {
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_method: method,
    p_reference: reference ?? undefined,
    p_received_at: receivedAt ?? undefined,
    p_notes: notes ?? undefined,
  })) as unknown as { balance: number; paid: boolean }
}

export async function listInvoicePayments(invoiceId: number): Promise<InvoicePayment[]> {
  return unwrap(await supabase.rpc('list_invoice_payments', { p_invoice_id: invoiceId })) as unknown as InvoicePayment[]
}

export async function deleteInvoicePayment(paymentId: number): Promise<void> {
  unwrap(await supabase.rpc('delete_invoice_payment', { p_payment_id: paymentId }))
}

// ── GL mirror (full P&L from the books) ─────────────────────────────────────

export async function glPnlMonthly(months = 12): Promise<GlPnlMonth[]> {
  return unwrap(await supabase.rpc('gl_pnl_monthly', { p_months: months })) as unknown as GlPnlMonth[]
}

export async function glExpenseBreakdown(months = 6): Promise<GlExpenseRow[]> {
  return unwrap(await supabase.rpc('gl_expense_breakdown', { p_months: months })) as unknown as GlExpenseRow[]
}

export async function glBreakevenMonthly(months = 12): Promise<GlBreakevenMonth[]> {
  return unwrap(await supabase.rpc('gl_breakeven_monthly', { p_months: months })) as unknown as GlBreakevenMonth[]
}

export async function glCfoSnapshot(): Promise<CfoSnapshot> {
  return unwrap(await supabase.rpc('gl_cfo_snapshot')) as unknown as CfoSnapshot
}

/** Email the invoice PDF to the customer's billing address (from trux@). */
export async function emailInvoice(invoiceId: number, pdfBase64: string, to?: string): Promise<{ ok: boolean; to: string }> {
  const { data, error } = await supabase.functions.invoke('invoice-send', {
    body: { invoice_id: invoiceId, pdf_base64: pdfBase64, to },
  })
  if (error) {
    // surface the function's error body when available
    const ctx = (error as { context?: Response }).context
    if (ctx) {
      const body = await ctx.json().catch(() => null) as { error?: string } | null
      if (body?.error) throw new Error(body.error)
    }
    throw error
  }
  return data as { ok: boolean; to: string }
}

// ── QuickBooks sync (transition mode: QBO is the books of record) ───────────

export async function qboStatus(): Promise<QboStatus> {
  return unwrap(await supabase.rpc('qbo_status')) as unknown as QboStatus
}

/** Connect URL opens the OAuth consent in a new tab; the fn validates the JWT. */
export async function qboConnectUrl(): Promise<string> {
  const { data } = await supabase.auth.getSession()
  const token = data.session?.access_token ?? ''
  return `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/qbo-sync?mode=connect&token=${encodeURIComponent(token)}`
}

export async function triggerQboPull(): Promise<Record<string, number>> {
  const { data, error } = await supabase.functions.invoke('qbo-sync', { body: { mode: 'pull' } })
  if (error) throw error
  return data as Record<string, number>
}

/** Invoice with its customer and full load rows — used for PDF generation. */
export interface InvoiceFull {
  invoice_number: string
  invoice_date: string
  due_date: string | null
  total: number
  customer: { company_name: string; billing_address: string; payment_terms: string }
  loads: { load_number: string; pickup_address: string; delivery_address: string; miles: number; rate: number }[]
}

export async function getInvoiceFull(id: number): Promise<InvoiceFull> {
  return unwrap(
    await supabase
      .from('invoices')
      .select('*, customer:customers(company_name, billing_address, payment_terms), loads(*)')
      .eq('id', id)
      .single(),
  )
}

// ---------- Documents (Supabase Storage + metadata table) ----------

export async function listDocuments(entityType: string, entityId: number | string): Promise<DocumentMeta[]> {
  return unwrap(
    await supabase
      .from('documents')
      .select('*')
      .eq('entity_type', entityType)
      .eq('entity_id', Number(entityId))
      .order('uploaded_at', { ascending: false }),
  )
}

export async function uploadDocument(entityType: string, entityId: number | string, file: File, docType: string): Promise<void> {
  const safeName = file.name.replace(/[^A-Za-z0-9._-]/g, '_')
  const path = `${entityType}/${entityId}/${crypto.randomUUID().slice(0, 12)}_${safeName}`
  const { error: uploadError } = await supabase.storage.from('documents').upload(path, file, { contentType: file.type })
  if (uploadError) throw new Error(uploadError.message)

  const { data: userData } = await supabase.auth.getUser()
  const { error: insertError } = await supabase.from('documents').insert({
    entity_type: entityType,
    entity_id: Number(entityId),
    doc_type: docType,
    filename: file.name,
    storage_path: path,
    content_type: file.type || 'application/octet-stream',
    size_bytes: file.size,
    uploaded_by: userData.user?.id,
  })
  if (insertError) {
    // Metadata is the source of truth — without the row the upload is an
    // invisible orphan, so clean it up (best-effort) before surfacing.
    await supabase.storage.from('documents').remove([path]).catch(() => {})
    throw new Error(insertError.message)
  }

  // Notify linked driver when load paperwork is uploaded (best-effort).
  if (entityType === 'load') {
    void supabase.functions
      .invoke('notify', {
        body: {
          action: 'notify_load',
          load_id: Number(entityId),
          type: 'paperwork',
          title: 'New paperwork',
          body: docType || file.name,
        },
      })
      .catch(() => {})
  }
}

export async function downloadDocument(doc: DocumentMeta): Promise<void> {
  const { data, error } = await supabase.storage.from('documents').download(doc.storage_path)
  if (error) throw new Error(error.message)
  const url = URL.createObjectURL(data)
  const a = document.createElement('a')
  a.href = url
  a.download = doc.filename
  a.click()
  URL.revokeObjectURL(url)
}

// ---------- Document semantic search (RAG) ----------

export interface DocSearchMatch {
  document_id: number | null
  drive_file_id: number | null
  entity_type: string
  entity_id: number
  filename: string
  doc_type: string | null
  content: string
  similarity: number
}

/** Enqueue a semantic search; the NAS worker embeds the query + runs the match.
 *  Polls the request row until it's done/error (or times out). */
export async function searchDocuments(
  query: string,
  entityType?: string,
  opts: { timeoutMs?: number; intervalMs?: number } = {},
): Promise<DocSearchMatch[]> {
  const timeoutMs = opts.timeoutMs ?? 25_000
  const intervalMs = opts.intervalMs ?? 1_200
  const { data: id, error } = await supabase.rpc('enqueue_doc_search', {
    p_query: query,
    p_entity_type: entityType ?? undefined,
  })
  if (error) throw new Error(error.message)

  const deadline = Date.now() + timeoutMs
  for (;;) {
    await new Promise((r) => setTimeout(r, intervalMs))
    const { data, error: pErr } = await supabase
      .from('doc_search_requests')
      .select('status, results, error')
      .eq('id', id as number)
      .single()
    if (pErr) throw new Error(pErr.message)
    if (data?.status === 'done') return (data.results as DocSearchMatch[] | null) ?? []
    if (data?.status === 'error') throw new Error(String(data.error ?? 'search failed'))
    if (Date.now() > deadline) throw new Error('Search timed out — the indexer may be busy. Try again in a moment.')
  }
}

/** Download a Team Drive file by its drive_files id (search results carry ids). */
export async function downloadTeamDriveFileById(driveFileId: number): Promise<void> {
  const { data: f, error } = await supabase
    .from('drive_files')
    .select('storage_path, filename')
    .eq('id', driveFileId)
    .single()
  if (error || !f?.storage_path) throw new Error(error?.message ?? 'File not found')
  const { data, error: dErr } = await supabase.storage.from('team').download(f.storage_path)
  if (dErr) throw new Error(dErr.message)
  const url = URL.createObjectURL(data)
  const a = document.createElement('a')
  a.href = url
  a.download = f.filename ?? 'download'
  a.click()
  URL.revokeObjectURL(url)
}

/** Download a document by its id (search results carry the id, not the path). */
export async function downloadDocumentById(documentId: number): Promise<void> {
  const { data: doc, error } = await supabase
    .from('documents')
    .select('storage_path, filename')
    .eq('id', documentId)
    .single()
  if (error || !doc) throw new Error(error?.message ?? 'Document not found')
  const { data, error: dErr } = await supabase.storage.from('documents').download(doc.storage_path)
  if (dErr) throw new Error(dErr.message)
  const url = URL.createObjectURL(data)
  const a = document.createElement('a')
  a.href = url
  a.download = doc.filename
  a.click()
  URL.revokeObjectURL(url)
}

// ---------- Activity / Notes ----------

export async function listActivity(entityType: string, entityId: number | string): Promise<Activity[]> {
  const rows = unwrap(
    await supabase
      .from('activity_log')
      .select('*, user:profiles(username, full_name)')
      .eq('entity_type', entityType)
      .eq('entity_id', Number(entityId))
      .order('created_at', { ascending: false })
      .limit(200),
  )
  return rows.map(({ user, ...row }) => ({ ...row, user_name: user ? user.full_name || user.username : null }))
}

export async function addNote(entityType: string, entityId: number | string, detail: string): Promise<void> {
  const { data: userData } = await supabase.auth.getUser()
  unwrap(
    await supabase.from('activity_log').insert({
      entity_type: entityType,
      entity_id: Number(entityId),
      action: 'note',
      detail,
      user_id: userData.user?.id,
    }),
  )
}

// ---------- Reports / Dashboard / Search ----------

export async function weeklyReport(weekOf: string): Promise<WeeklyReport> {
  return unwrap(await supabase.rpc('weekly_report', { p_week_of: weekOf })) as unknown as WeeklyReport
}

export async function dashboardSummary(): Promise<DashboardSummary> {
  return unwrap(await supabase.rpc('dashboard_summary')) as unknown as DashboardSummary
}

export async function globalSearch(q: string): Promise<SearchResults> {
  return unwrap(await supabase.rpc('global_search', { q })) as unknown as SearchResults
}

// ---------- Fuel ----------

export interface FuelFilters {
  start?: string
  end?: string
  state?: string
  truckId?: number
}

/** Recent fuel-card transactions (RLS limits to admin/accountant/dispatcher). */
export async function listFuelTransactions(filters: FuelFilters = {}): Promise<Tables<'fuel_transactions'>[]> {
  let query = supabase.from('fuel_transactions').select('*').order('transaction_time', { ascending: false }).limit(200)
  if (filters.start) query = query.gte('transaction_time', filters.start)
  if (filters.end) query = query.lte('transaction_time', filters.end + 'T23:59:59')
  if (filters.state) query = query.eq('merchant_state', filters.state)
  if (filters.truckId) query = query.eq('truck_id', filters.truckId)
  return unwrap(await query)
}

/** Spend/gallons rolled up per truck over the range (server sorts by spend desc). */
export async function fuelByTruck(start: string, end: string): Promise<FuelByTruckRow[]> {
  const data = unwrap(await supabase.rpc('fuel_by_truck', { p_start: start, p_end: end }))
  return (data as unknown as FuelByTruckRow[]) ?? []
}

/** IFTA rollup per jurisdiction over the range. */
export async function fuelIftaSummary(start: string, end: string): Promise<FuelIftaRow[]> {
  const data = unwrap(await supabase.rpc('fuel_ifta_summary', { p_start: start, p_end: end }))
  return (data as unknown as FuelIftaRow[]) ?? []
}

// ---------- Tolls ----------

export interface TollFilters {
  start?: string
  end?: string
  state?: string
  truckId?: number
  category?: string
}

/** Recent PrePass toll transactions (RLS limits to admin/accountant/dispatcher). */
export async function listTollTransactions(filters: TollFilters = {}): Promise<Tables<'toll_transactions'>[]> {
  let query = supabase.from('toll_transactions').select('*').order('post_date_time', { ascending: false }).limit(200)
  if (filters.start) query = query.gte('post_date_time', filters.start)
  if (filters.end) query = query.lte('post_date_time', filters.end + 'T23:59:59')
  if (filters.state) query = query.eq('toll_agency_state', filters.state)
  if (filters.truckId) query = query.eq('truck_id', filters.truckId)
  if (filters.category) query = query.eq('toll_category', filters.category)
  return unwrap(await query)
}

/** Toll spend/counts rolled up per truck over the range (server sorts by spend desc). */
export async function tollByTruck(start: string, end: string): Promise<TollByTruckRow[]> {
  const data = unwrap(await supabase.rpc('toll_by_truck', { p_start: start, p_end: end }))
  return (data as unknown as TollByTruckRow[]) ?? []
}

/** Toll rollup per agency / jurisdiction over the range. */
export async function tollByAgency(start: string, end: string): Promise<TollByAgencyRow[]> {
  const data = unwrap(await supabase.rpc('toll_by_agency', { p_start: start, p_end: end }))
  return (data as unknown as TollByAgencyRow[]) ?? []
}

// ---------- Edge functions ----------

/** Invoke an edge function, surfacing the server's JSON error body — on
 * non-2xx, FunctionsHttpError.message is a fixed generic string and the real
 * message (403 role denial, 413 too large, 429 rate limit…) is only on
 * error.context. */
async function invokeFunction<T>(name: string, options: { method?: 'GET' | 'POST' | 'PATCH'; body?: Row | FormData }): Promise<T> {
  const { data, error } = await supabase.functions.invoke(name, options)
  if (error) {
    const context = (error as { context?: Response }).context
    if (context) {
      const body = await context.json().catch(() => null)
      if (body?.error) throw new Error(body.error)
    }
    throw new Error(error.message)
  }
  return data as T
}

// ---------- Users (admin edge function) ----------

function invokeAdminUsers<T>(options: { method: 'GET' | 'POST' | 'PATCH'; body?: Row }): Promise<T> {
  return invokeFunction<T>('admin-users', options)
}

export async function listUsers(): Promise<Profile[]> {
  return invokeAdminUsers<Profile[]>({ method: 'GET' })
}

export async function createUser(payload: Row): Promise<void> {
  const body = { ...payload }
  if (body.link_driver_id === '' || body.link_driver_id == null) {
    delete body.link_driver_id
  } else {
    body.link_driver_id = Number(body.link_driver_id)
  }
  await invokeAdminUsers({ method: 'POST', body })
}

export async function updateUser(id: string, payload: Row): Promise<void> {
  await invokeAdminUsers({ method: 'PATCH', body: { id, ...payload } })
}

// ---------- Personal / Team drives (nested folders) ----------
// Storage bytes stay flat in the bucket; the folder tree is metadata (parent +
// is_folder). Move/rename are RPCs that rewrite descendant paths.

export type DriveName = 'personal' | 'team'

export interface DriveItem {
  id: number
  drive: DriveName
  owner_id: string
  filename: string
  storage_path: string | null
  content_type: string
  size_bytes: number
  parent: string
  is_folder: boolean
  uploaded_at: string
  owner_name?: string | null
}

export interface DriveFolderPath {
  id: number
  path: string
}

type DriveRow = Tables<'drive_files'> & { owner: Pick<Tables<'profiles'>, 'username' | 'full_name'> | null }

function mapDriveItem(drive: DriveName, { owner, ...f }: DriveRow): DriveItem {
  return { ...f, drive, owner_name: owner ? owner.full_name || owner.username : null }
}

/** Items directly inside `parent` ('' = root); folders first, then by name. */
export async function listDriveItems(drive: DriveName, parent: string): Promise<DriveItem[]> {
  const rows = unwrap(
    await supabase
      .from('drive_files')
      .select('*, owner:profiles(username, full_name)')
      .eq('drive', drive)
      .eq('parent', parent)
      .order('is_folder', { ascending: false })
      .order('filename', { ascending: true }),
  )
  return (rows as unknown as DriveRow[]).map((r) => mapDriveItem(drive, r))
}

/** Name-match across the whole drive (folders + files) for the search box. */
export async function searchDriveItems(drive: DriveName, q: string): Promise<DriveItem[]> {
  const term = sanitizeSearchTerm(q)
  if (!term) return []
  const rows = unwrap(
    await supabase
      .from('drive_files')
      .select('*, owner:profiles(username, full_name)')
      .eq('drive', drive)
      .ilike('filename', `%${term}%`)
      .order('is_folder', { ascending: false })
      .order('filename', { ascending: true })
      .limit(200),
  )
  return (rows as unknown as DriveRow[]).map((r) => mapDriveItem(drive, r))
}

/** Every folder as a full path (for the "Move to…" picker). */
export async function listDriveFolderPaths(drive: DriveName): Promise<DriveFolderPath[]> {
  const rows = unwrap(await supabase.from('drive_files').select('id, filename, parent').eq('drive', drive).eq('is_folder', true))
  return rows
    .map((r) => ({ id: r.id as number, path: r.parent ? `${r.parent}/${r.filename}` : (r.filename as string) }))
    .sort((a, b) => a.path.localeCompare(b.path))
}

export async function createDriveFolder(drive: DriveName, parent: string, name: string): Promise<void> {
  const { data: userData } = await supabase.auth.getUser()
  const uid = userData.user?.id
  if (!uid) throw new Error('Not signed in')
  const clean = name.trim().replace(/[/\\]/g, '_')
  if (!clean) throw new Error('Folder name required')
  unwrap(
    await supabase.from('drive_files').insert({
      drive, owner_id: uid, filename: clean, storage_path: null, content_type: '', size_bytes: 0, parent, is_folder: true,
    }),
  )
}

export async function uploadDriveFile(drive: DriveName, file: File, parent = ''): Promise<void> {
  const { data: userData } = await supabase.auth.getUser()
  const uid = userData.user?.id
  if (!uid) throw new Error('Not signed in')
  const safeName = file.name.replace(/[^A-Za-z0-9._-]/g, '_')
  const path = `${uid}/${crypto.randomUUID().slice(0, 12)}_${safeName}`
  const { error: upErr } = await supabase.storage.from(drive).upload(path, file, { contentType: file.type })
  if (upErr) throw new Error(upErr.message)
  unwrap(
    await supabase.from('drive_files').insert({
      drive, owner_id: uid, filename: file.name, storage_path: path,
      content_type: file.type || 'application/octet-stream', size_bytes: file.size, parent, is_folder: false,
    }),
  )
}

/** Short-lived signed URL for preview/download (no in-memory blob). */
export async function driveSignedUrl(drive: DriveName, path: string, downloadName?: string): Promise<string> {
  const { data, error } = await supabase.storage.from(drive).createSignedUrl(path, 3600, downloadName ? { download: downloadName } : undefined)
  if (error) throw new Error(error.message)
  return data.signedUrl
}

export async function downloadDriveItem(item: DriveItem): Promise<void> {
  if (!item.storage_path) return
  const url = await driveSignedUrl(item.drive, item.storage_path, item.filename)
  const a = document.createElement('a')
  a.href = url
  a.rel = 'noopener'
  a.click()
}

export async function renameDriveItem(id: number, name: string): Promise<void> {
  unwrap(await supabase.rpc('drive_rename', { p_id: id, p_new_name: name }))
}

export async function moveDriveItems(ids: number[], parent: string): Promise<void> {
  unwrap(await supabase.rpc('drive_move', { p_ids: ids, p_new_parent: parent }))
}

/** Delete items (folders take their subtree); the RPC returns storage paths to
 * purge, which we then remove from the bucket in chunks. */
export async function deleteDriveItems(drive: DriveName, ids: number[]): Promise<void> {
  const raw = unwrap(await supabase.rpc('drive_delete', { p_ids: ids })) as unknown
  const paths: string[] = Array.isArray(raw)
    ? raw
        .map((x) => (typeof x === 'string' ? x : x && typeof x === 'object' ? String(Object.values(x)[0] ?? '') : ''))
        .filter((p) => p)
    : []
  for (let i = 0; i < paths.length; i += 100) {
    await supabase.storage.from(drive).remove(paths.slice(i, i + 100))
  }
}

/** Ensure a nested folder path exists (used by folder upload). */
export async function ensureDrivePath(drive: DriveName, path: string): Promise<void> {
  unwrap(await supabase.rpc('drive_ensure_path', { p_drive: drive, p_path: path }))
}

// ---------- public share links ----------

export interface DriveShare {
  id: number
  token: string
  drive_file_id: number
  created_at: string
  expires_at: string | null
  revoked: boolean
}

/** Create a public download link for a file; returns the token. */
export async function createDriveShare(fileId: number, expiresAt?: string): Promise<string> {
  return unwrap(await supabase.rpc('drive_create_share', { p_file_id: fileId, p_expires_at: expiresAt })) as unknown as string
}

/** The public URL anyone can use to download the shared file. */
export function driveShareUrl(token: string): string {
  return `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/drive-share?t=${token}`
}

export async function listDriveShares(fileId: number): Promise<DriveShare[]> {
  return unwrap(
    await supabase
      .from('drive_shares')
      .select('id, token, drive_file_id, created_at, expires_at, revoked')
      .eq('drive_file_id', fileId)
      .eq('revoked', false)
      .order('created_at', { ascending: false }),
  ) as unknown as DriveShare[]
}

export async function revokeDriveShare(id: number): Promise<void> {
  unwrap(await supabase.from('drive_shares').update({ revoked: true }).eq('id', id))
}

// ---------- Trux Sentinel insights ----------

export interface TruxInsight {
  id: number
  dedup_key: string
  category: 'money' | 'cash' | 'ops' | 'compliance' | 'maintenance'
  severity: 'info' | 'warn' | 'critical'
  title: string
  detail: string
  entity_type: string
  entity_id: number | null
  status: 'open' | 'acknowledged' | 'resolved'
  first_seen: string
  last_seen: string
}

export async function listInsights(includeResolved = false): Promise<TruxInsight[]> {
  return unwrap(await supabase.rpc('trux_insights_feed', { p_include_resolved: includeResolved })) as unknown as TruxInsight[]
}

export async function acknowledgeInsight(id: number): Promise<void> {
  unwrap(await supabase.rpc('acknowledge_insight', { p_id: id }))
}

// ---------- Trux premium voice ----------

/** POST answer text to the trux-tts edge function; returns MP3 audio (the key
 * stays server-side). Throws on any non-2xx so the caller can fall back to the
 * free browser voice. */
export async function synthesizeSpeech(text: string): Promise<Blob> {
  const { data } = await supabase.auth.getSession()
  const res = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/trux-tts`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${data.session?.access_token ?? ''}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ text }),
  })
  if (!res.ok) throw new Error(`Voice ${res.status}`)
  return res.blob()
}

// ---------- Company settings ----------

export interface CompanySettings {
  id: number
  company_name: string
  address: string
  phone: string
  email: string
  mc_number: string
  usdot_number: string
  logo_path: string
}

export async function getCompanySettings(): Promise<CompanySettings> {
  return unwrap(await supabase.from('company_settings').select('*').eq('id', 1).single())
}

export async function updateCompanySettings(payload: Partial<CompanySettings>): Promise<CompanySettings> {
  return unwrap(await supabase.from('company_settings').update(payload).eq('id', 1).select().single())
}

// ---------- Dispatch helpers (edge functions) ----------

export interface ExtractedStop {
  type?: 'pickup' | 'delivery' | null
  facility?: string | null
  address?: string | null
  datetime?: string | null
  reference?: string | null
}

export interface ExtractResult {
  raw_text: string
  fields: {
    customer_name?: string | null
    reference_number?: string | null
    equipment_type?: string | null
    pickup_number?: string | null
    delivery_number?: string | null
    pickup_address?: string | null
    pickup_time?: string | null
    delivery_address?: string | null
    delivery_time?: string | null
    rate?: number | null
    special_terms?: string | null
    stops?: ExtractedStop[] | null
  } | null
  /** Set when the PDF has no text layer — retry with rendered page images. */
  needs_images?: boolean
  error: string | null
}

export async function extractPdf(file: File, pageImages: Blob[] = []): Promise<ExtractResult> {
  const form = new FormData()
  form.append('file', file)
  pageImages.forEach((img, i) => form.append(`page${i}`, new File([img], `page${i}.jpg`, { type: 'image/jpeg' })))
  return invokeFunction<ExtractResult>('extract-pdf', { body: form })
}

/** Customer-profile extraction (Customers quick-add) — same function and
 * rate limit as load extraction, different prompt. */
export interface CustomerExtract {
  raw_text: string
  fields: {
    company_name?: string | null
    contact_person?: string | null
    phone?: string | null
    email?: string | null
    billing_address?: string | null
    payment_terms?: string | null
    mc_number?: string | null
    notes?: string | null
  } | null
  needs_images?: boolean
  error: string | null
}

export async function extractCustomerPdf(file: File, pageImages: Blob[] = []): Promise<CustomerExtract> {
  const form = new FormData()
  form.append('file', file)
  form.append('mode', 'customer')
  pageImages.forEach((img, i) => form.append(`page${i}`, new File([img], `page${i}.jpg`, { type: 'image/jpeg' })))
  return invokeFunction<CustomerExtract>('extract-pdf', { body: form })
}

/** Maintenance work-order / shop-invoice extraction (Maintenance add-from-sheet)
 * — same function and rate limit, work_order prompt. A photo (image file) is
 * also sent as page0 so the vision model handles it. */
export interface WorkOrderExtract {
  raw_text: string
  fields: {
    unit_number?: string | null
    vin?: string | null
    service_type?: string | null
    description?: string | null
    cost?: number | string | null
    odometer?: number | string | null
    date?: string | null
    vendor?: string | null
    invoice_ref?: string | null
  } | null
  needs_images?: boolean
  error: string | null
}

export async function extractWorkOrderSheet(file: File): Promise<WorkOrderExtract> {
  const form = new FormData()
  form.append('mode', 'work_order')
  form.append('file', file)
  if (file.type.startsWith('image/')) form.append('page0', file)
  return invokeFunction<WorkOrderExtract>('extract-pdf', { body: form })
}

export async function calculateDistance(
  origin: string,
  destination: string,
  waypoints: string[] = [],
): Promise<{ miles: number | null; available: boolean }> {
  return invokeFunction<{ miles: number | null; available: boolean }>('distance', { body: { origin, destination, waypoints } })
}

/** Admin-only: push a fuel-card CSV export to the importer (matches trucks by
 * unit, upserts by uuid). The admin's JWT is sent automatically by invoke. */
export async function importFuelCsv(csvText: string): Promise<FuelImportResult> {
  return invokeFunction<FuelImportResult>('fuel-import', { body: { csv: csvText } })
}

// ---------- Equipment enrichment: registration conflicts ----------

/** An open enrichment conflict: a registration/title value that disagrees with
 *  what's already on the truck/trailer record. Admin resolves each one. */
export interface EquipmentConflict {
  log_id: number
  equipment_type: 'truck' | 'trailer'
  equipment_id: number
  unit_number: string | null
  field: string
  old_value: string | null
  new_value: string
  source_document_id: number | null
  source_filename: string | null
  model: string | null
  created_at: string
}

/** Admin-only: open conflicts awaiting a keep/accept decision. */
export async function listEquipmentConflicts(): Promise<EquipmentConflict[]> {
  const data = unwrap(await supabase.rpc('equipment_conflicts'))
  return (data as unknown as EquipmentConflict[]) ?? []
}

/** Resolve one conflict: 'keep' the value on file, or 'accept' the document's. */
export async function resolveEquipmentConflict(logId: number, action: 'keep' | 'accept'): Promise<void> {
  unwrap(await supabase.rpc('resolve_equipment_conflict', { p_log_id: logId, p_action: action }))
}

// ---------- Missing POD: attach from the PODs archive ----------

/** The Team-Drive PODs file that matches a load, ready to copy in. null if none. */
export interface PodArchiveFile {
  drive_file_id: number
  filename: string
  storage_path: string
  content_type: string | null
}

export async function podArchiveCandidate(loadId: number): Promise<PodArchiveFile | null> {
  const rows = unwrap(await supabase.rpc('pod_archive_candidate_file', { p_load_id: loadId })) as unknown as PodArchiveFile[]
  return rows?.[0] ?? null
}

/** Copy the matching archive file into the load's Documents as a POD. */
export async function attachPodFromArchive(loadId: number): Promise<string> {
  const cand = await podArchiveCandidate(loadId)
  if (!cand) throw new Error('No matching file found in the PODs archive')
  const { data: blob, error } = await supabase.storage.from('team').download(cand.storage_path)
  if (error || !blob) throw new Error(error?.message ?? 'Could not read the archive file')
  const type = cand.content_type || blob.type || 'application/octet-stream'
  await uploadDocument('load', loadId, new File([blob], cand.filename, { type }), 'POD')
  return cand.filename
}

// ---------- FMCSA safety watch ----------

export interface CarrierSafetySnapshot {
  snapshot_date: string
  dot_number: string
  legal_name: string
  safety_rating: string
  safety_rating_date: string | null
  allowed_to_operate: string
  driver_oos_rate: number | null
  driver_oos_natl: number | null
  vehicle_oos_rate: number | null
  vehicle_oos_natl: number | null
  crash_total: number | null
  fatal_crash: number | null
  total_power_units: number | null
  iss_score: number | null
}
export interface SafetyBasic { basic: string; percentile: number | null; measure: number | null; alert: boolean }
export interface CarrierSafety {
  snapshot: CarrierSafetySnapshot | null
  rating_label: string | null
  basics: SafetyBasic[]
  usdot: string
}

/** Latest FMCSA snapshot + BASICs for the Safety card. */
export async function carrierSafety(): Promise<CarrierSafety> {
  const d = unwrap(await supabase.rpc('carrier_safety_latest')) as unknown as CarrierSafety & { error?: string }
  return { snapshot: d?.snapshot ?? null, rating_label: d?.rating_label ?? null, basics: d?.basics ?? [], usdot: d?.usdot ?? '' }
}

/** Admin: pull a fresh FMCSA profile now (the weekly cron does this automatically). */
export async function runFmcsaCheck(): Promise<Record<string, unknown>> {
  return invokeFunction('fmcsa-watch', { body: {} })
}

// ---------- ELD telematics (live fleet) ----------

export interface EldFleetRow {
  vehicle_id: string
  unit: string | null
  vin: string | null
  truck_id: number | null
  lat: number | null
  lng: number | null
  speed: number | null
  odometer: number | null
  fuel_level: number | null
  status: string | null
  location: string | null
  ts: string | null
  driver_name: string | null
  hos_drive_sec: number | null
  hos_shift_sec: number | null
  hos_cycle_sec: number | null
  duty_status: string | null
}

/** Latest ELD position + driver HOS for every active vehicle. */
export async function eldFleetLive(): Promise<EldFleetRow[]> {
  const data = unwrap(await supabase.rpc('eld_fleet_live'))
  return (data as unknown as EldFleetRow[]) ?? []
}

/** Admin: pull a fresh ELD sync now (the 15-min cron does this automatically). */
export async function eldSyncNow(): Promise<Record<string, unknown>> {
  return invokeFunction('eld-sync', { body: {} })
}

/** Merged live fleet for the map: the ELD is the source of truth (accurate,
 *  always on). Our companion tablets are FAILOVER ONLY — a tablet pin appears
 *  solely for a fleet truck the ELD isn't currently reporting. */
export async function fleetLive(): Promise<FleetPin[]> {
  const [eld, mobile] = await Promise.all([
    eldFleetLive().catch(() => [] as EldFleetRow[]),
    fleetPositionsSnapshot().catch(() => [] as FleetPin[]),
  ])
  const pins: FleetPin[] = []
  const covered = new Set<number>()
  // The ELD pads some units (e.g. "003"); show the 2-digit fleet form ("03").
  const tidyUnit = (u: string | null | undefined) => (u ?? '').replace(/^0(?=\d\d)/, '') || null
  eld.forEach((e, i) => {
    if (e.lat == null || e.lng == null) return
    if (e.truck_id) covered.add(e.truck_id)
    pins.push({
      driver_id: -(e.truck_id ?? i + 1), // synthetic (negative) key; no collision with real driver ids
      driver_name: e.driver_name ?? `Unit ${tidyUnit(e.unit) ?? '?'}`,
      truck_id: e.truck_id ?? null,
      truck_unit: tidyUnit(e.unit),
      load_id: null,
      load_number: null,
      lat: Number(e.lat),
      lng: Number(e.lng),
      speed_mps: e.speed != null ? Number(e.speed) * 0.44704 : null, // ELD reports mph → m/s for the shared formatter
      heading_deg: null,
      recorded_at: e.ts ?? new Date().toISOString(),
      source: 'eld',
      location: e.location,
      odometer: e.odometer,
      hos_drive_sec: e.hos_drive_sec,
      duty_status: e.duty_status,
      eld_status: e.status,
    })
  })
  // Failover only: skip tablets not tied to a fleet truck, and any truck the ELD
  // already covers — so no redundant tablet pins clutter the map.
  for (const m of mobile) {
    if (!m.truck_id || covered.has(m.truck_id)) continue
    pins.push({ ...m, source: 'mobile' })
  }
  return pins
}

// ---------- Northstar: predictive cash ----------

export interface CashflowWeek {
  week_start: string
  week_number: number
  week_label: string
  expected_in: number
  expected_out: number
  net: number
  cumulative_net: number
}
export interface SlowPayRow {
  invoice_id: number
  invoice_number: string
  customer: string
  customer_id: number
  total: number
  invoice_date: string
  due_date: string | null
  avg_days: number
  predicted_pay_date: string
  predicted_days_late: number
  risk: 'high' | 'medium' | 'low'
}

/** Weekly cash-flow forecast (expected in/out/net + running total). */
export async function cashflowForecast(weeks = 8): Promise<CashflowWeek[]> {
  const data = unwrap(await supabase.rpc('cashflow_forecast', { p_weeks: weeks }))
  return (data as unknown as CashflowWeek[]) ?? []
}

/** Open invoices ranked by predicted lateness (learned from pay behavior). */
export async function slowPayRisk(): Promise<SlowPayRow[]> {
  const data = unwrap(await supabase.rpc('slow_pay_risk'))
  return (data as unknown as SlowPayRow[]) ?? []
}

export interface RevenueForecastWeek {
  week_start: string
  week_number: number
  week_label: string
  forecast_revenue: number
  trailing_avg: number
  last_year_revenue: number | null
  loads_per_truck: number | null
  basis: string
}
/** Weekly revenue outlook (trailing avg blended with same week last year). */
export async function revenueForecast(weeks = 6): Promise<RevenueForecastWeek[]> {
  const data = unwrap(await supabase.rpc('revenue_forecast', { p_weeks: weeks }))
  return (data as unknown as RevenueForecastWeek[]) ?? []
}

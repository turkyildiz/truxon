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
  customer_id?: string | number
  driver_id?: string | number
  date_from?: string
  date_to?: string
}

export async function listLoads(filters: LoadFilters = {}): Promise<Load[]> {
  let query = supabase.from('loads').select(LOAD_SELECT).order('created_at', { ascending: false }).limit(200)
  if (filters.status) query = query.eq('status', filters.status as Tables<'loads'>['status'])
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
  return { ...invoice, customer_name: null, load_count: loadIds.length }
}

export async function setInvoiceStatus(id: number, status: string): Promise<void> {
  unwrap(await supabase.rpc('set_invoice_status', { p_invoice_id: id, p_status: status as Invoice['status'] }))
}

export async function voidInvoice(id: number): Promise<void> {
  unwrap(await supabase.rpc('void_invoice', { p_invoice_id: id }))
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

// ---------- Personal / Team drives ----------

export interface DriveFile {
  id: number
  drive: 'personal' | 'team'
  owner_id: string
  filename: string
  storage_path: string
  content_type: string
  size_bytes: number
  folder: string
  uploaded_at: string
  owner_name?: string | null
}

export async function listDriveFiles(drive: 'personal' | 'team', folder?: string): Promise<DriveFile[]> {
  let query = supabase
    .from('drive_files')
    .select('*, owner:profiles(username, full_name)')
    .eq('drive', drive)
    .order('uploaded_at', { ascending: false })
  if (folder !== undefined) query = query.eq('folder', folder)
  const rows = unwrap(await query)
  return rows.map(({ owner, ...f }) => ({ ...f, drive, owner_name: owner ? owner.full_name || owner.username : null }))
}

/** Distinct folder labels present in a drive (for the folder filter). */
export async function listDriveFolders(drive: 'personal' | 'team'): Promise<string[]> {
  const rows = unwrap(await supabase.from('drive_files').select('folder').eq('drive', drive))
  return [...new Set(rows.map((r) => r.folder).filter(Boolean))].sort()
}

export async function uploadDriveFile(drive: 'personal' | 'team', file: File, folder = ''): Promise<void> {
  const { data: userData } = await supabase.auth.getUser()
  const uid = userData.user?.id
  if (!uid) throw new Error('Not signed in')
  const safeName = file.name.replace(/[^A-Za-z0-9._-]/g, '_')
  const safeFolder = folder ? `${folder.replace(/[^A-Za-z0-9._ -]/g, '_')}/` : ''
  const path = `${uid}/${safeFolder}${crypto.randomUUID().slice(0, 12)}_${safeName}`
  const { error: upErr } = await supabase.storage.from(drive).upload(path, file, { contentType: file.type })
  if (upErr) throw new Error(upErr.message)
  unwrap(
    await supabase.from('drive_files').insert({
      drive,
      owner_id: uid,
      filename: file.name,
      storage_path: path,
      content_type: file.type || 'application/octet-stream',
      size_bytes: file.size,
      folder,
    }),
  )
}

export async function downloadDriveFile(f: DriveFile): Promise<void> {
  const { data, error } = await supabase.storage.from(f.drive).download(f.storage_path)
  if (error) throw new Error(error.message)
  const url = URL.createObjectURL(data)
  const a = document.createElement('a')
  a.href = url
  a.download = f.filename
  a.click()
  URL.revokeObjectURL(url)
}

export async function deleteDriveFile(f: DriveFile): Promise<void> {
  const { error: storageErr } = await supabase.storage.from(f.drive).remove([f.storage_path])
  if (storageErr) throw new Error(storageErr.message)
  unwrap(await supabase.from('drive_files').delete().eq('id', f.id))
}

// ---------- Company settings ----------

export interface CompanySettings {
  id: number
  company_name: string
  address: string
  phone: string
  email: string
  mc_number: string
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

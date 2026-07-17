/**
 * Data access layer — every Supabase query/RPC/storage/edge-function call
 * the app makes lives here, so pages stay free of query syntax.
 */
import { supabase, unwrap } from './supabase'
import type {
  Activity,
  Customer,
  DashboardSummary,
  DocumentMeta,
  Driver,
  Equipment,
  Invoice,
  Load,
  LoadStatus,
  MaintenanceRecord,
  Profile,
  SearchResults,
  WeeklyReport,
} from './types'

type Row = Record<string, unknown>

/**
 * Sanitize user search input before embedding in PostgREST filter strings.
 * Strips characters that rewrite filter grammar (, . ( ) *) and escapes ILIKE wildcards.
 */
export function sanitizeSearchTerm(q: string): string {
  return q
    .replace(/[%_\\]/g, '') // avoid ILIKE wildcard injection
    .replace(/[,.()*"'\\]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80)
}

// ---------- Customers ----------

export async function listCustomers(q?: string): Promise<Customer[]> {
  let query = supabase.from('customers').select('*').eq('is_active', true).order('company_name')
  const s = q ? sanitizeSearchTerm(q) : ''
  if (s) query = query.or(`company_name.ilike.%${s}%,contact_person.ilike.%${s}%`)
  return unwrap(await query)
}

export async function createCustomer(payload: Row): Promise<Customer> {
  return unwrap(await supabase.from('customers').insert(payload).select().single())
}

export async function updateCustomer(id: number, payload: Row): Promise<Customer> {
  return unwrap(await supabase.from('customers').update(payload).eq('id', id).select().single())
}

// ---------- Drivers ----------

export async function listDrivers(q?: string): Promise<Driver[]> {
  let query = supabase.from('drivers').select('*').order('full_name')
  const s = q ? sanitizeSearchTerm(q) : ''
  if (s) query = query.ilike('full_name', `%${s}%`)
  return unwrap(await query)
}

/** Driver-role profiles that can be linked (or the currently linked profile). */
export async function listLinkableDriverProfiles(currentUserId?: string | null): Promise<Profile[]> {
  const { data: profiles, error } = await supabase
    .from('profiles')
    .select('id, username, full_name, role, is_active')
    .eq('role', 'driver')
    .eq('is_active', true)
    .order('username')
  if (error) throw error
  const drivers = await listDrivers()
  const taken = new Set(drivers.map((d) => d.user_id).filter(Boolean) as string[])
  return (profiles ?? []).filter((p) => !taken.has(p.id) || p.id === currentUserId)
}

export async function createDriver(payload: Row): Promise<Driver> {
  return unwrap(await supabase.from('drivers').insert(payload).select().single())
}

export async function updateDriver(id: number, payload: Row): Promise<Driver> {
  return unwrap(await supabase.from('drivers').update(payload).eq('id', id).select().single())
}

// ---------- Trucks / Trailers ----------

function equipmentApi(table: 'trucks' | 'trailers') {
  return {
    async list(q?: string): Promise<Equipment[]> {
      let query = supabase.from(table).select('*').order('unit_number')
      const s = q ? sanitizeSearchTerm(q) : ''
      if (s) query = query.ilike('unit_number', `%${s}%`)
      return unwrap(await query)
    },
    async create(payload: Row): Promise<Equipment> {
      return unwrap(await supabase.from(table).insert(payload).select().single())
    },
    async update(id: number, payload: Row): Promise<Equipment> {
      return unwrap(await supabase.from(table).update(payload).eq('id', id).select().single())
    },
  }
}

export const trucksApi = equipmentApi('trucks')
export const trailersApi = equipmentApi('trailers')

// ---------- Maintenance ----------

const MAINTENANCE_SELECT = '*, truck:trucks(unit_number), trailer:trailers(unit_number)'

function mapMaintenance(row: Row): MaintenanceRecord {
  const truck = row.truck as { unit_number: string } | null
  const trailer = row.trailer as { unit_number: string } | null
  return {
    ...(row as unknown as MaintenanceRecord),
    equipment_unit: row.equipment_type === 'truck' ? truck?.unit_number ?? null : trailer?.unit_number ?? null,
  }
}

export async function listMaintenance(): Promise<MaintenanceRecord[]> {
  const rows = unwrap<Row[]>(
    await supabase.from('maintenance_records').select(MAINTENANCE_SELECT).order('date_completed', { ascending: false, nullsFirst: false }),
  )
  return rows.map(mapMaintenance)
}

export async function createMaintenance(payload: Row): Promise<MaintenanceRecord> {
  return mapMaintenance(unwrap(await supabase.from('maintenance_records').insert(payload).select(MAINTENANCE_SELECT).single()))
}

export async function updateMaintenance(id: number, payload: Row): Promise<MaintenanceRecord> {
  return mapMaintenance(unwrap(await supabase.from('maintenance_records').update(payload).eq('id', id).select(MAINTENANCE_SELECT).single()))
}

// ---------- Loads ----------

const LOAD_SELECT =
  '*, customer:customers(company_name), driver:drivers(full_name), truck:trucks(unit_number), trailer:trailers(unit_number)'

function mapLoad(row: Row): Load {
  const customer = row.customer as { company_name: string } | null
  const driver = row.driver as { full_name: string } | null
  const truck = row.truck as { unit_number: string } | null
  const trailer = row.trailer as { unit_number: string } | null
  const rate = Number(row.rate)
  const miles = Number(row.miles)
  return {
    ...(row as unknown as Load),
    customer_name: customer?.company_name ?? null,
    driver_name: driver?.full_name ?? null,
    truck_unit: truck?.unit_number ?? null,
    trailer_unit: trailer?.unit_number ?? null,
    rate_per_mile: miles > 0 ? Math.round((rate / miles) * 100) / 100 : null,
  }
}

export interface LoadFilters {
  q?: string
  status?: string
  customer_id?: string | number
  date_from?: string
  date_to?: string
}

export async function listLoads(filters: LoadFilters = {}): Promise<Load[]> {
  let query = supabase.from('loads').select(LOAD_SELECT).order('created_at', { ascending: false }).limit(200)
  if (filters.status) query = query.eq('status', filters.status)
  if (filters.customer_id) query = query.eq('customer_id', filters.customer_id)
  if (filters.date_from) query = query.gte('pickup_time', filters.date_from)
  if (filters.date_to) query = query.lte('pickup_time', filters.date_to + 'T23:59:59')
  if (filters.q) {
    const s = sanitizeSearchTerm(filters.q)
    if (s) {
      query = query.or(`load_number.ilike.%${s}%,pickup_address.ilike.%${s}%,delivery_address.ilike.%${s}%`)
    }
  }
  const rows = unwrap<Row[]>(await query)
  return rows.map(mapLoad)
}

export async function getLoad(id: number | string): Promise<Load> {
  return mapLoad(unwrap(await supabase.from('loads').select(LOAD_SELECT).eq('id', id).single()))
}

export async function createLoad(payload: Row): Promise<Load> {
  return mapLoad(unwrap(await supabase.from('loads').insert(payload).select(LOAD_SELECT).single()))
}

export async function updateLoad(id: number | string, payload: Row): Promise<Load> {
  return mapLoad(unwrap(await supabase.from('loads').update(payload).eq('id', id).select(LOAD_SELECT).single()))
}

export async function changeLoadStatus(id: number | string, status: LoadStatus): Promise<void> {
  unwrap(await supabase.rpc('change_load_status', { p_load_id: Number(id), p_status: status }))
}

// ---------- Invoices ----------

const INVOICE_SELECT = '*, customer:customers(company_name), loads(id)'

function mapInvoice(row: Row): Invoice {
  const customer = row.customer as { company_name: string } | null
  const loads = row.loads as { id: number }[] | null
  return {
    ...(row as unknown as Invoice),
    customer_name: customer?.company_name ?? null,
    load_count: loads?.length ?? 0,
  }
}

export async function listInvoices(): Promise<Invoice[]> {
  const rows = unwrap<Row[]>(await supabase.from('invoices').select(INVOICE_SELECT).order('created_at', { ascending: false }))
  return rows.map(mapInvoice)
}

export async function createInvoice(customerId: number, loadIds: number[]): Promise<Invoice> {
  return unwrap(await supabase.rpc('create_invoice', { p_customer_id: customerId, p_load_ids: loadIds }))
}

export async function setInvoiceStatus(id: number, status: string): Promise<void> {
  unwrap(await supabase.rpc('set_invoice_status', { p_invoice_id: id, p_status: status }))
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
  return unwrap<InvoiceFull>(
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
      .eq('entity_id', entityId)
      .order('uploaded_at', { ascending: false }),
  )
}

export async function uploadDocument(entityType: string, entityId: number | string, file: File, docType: string): Promise<void> {
  const safeName = file.name.replace(/[^A-Za-z0-9._-]/g, '_')
  const path = `${entityType}/${entityId}/${crypto.randomUUID().slice(0, 12)}_${safeName}`
  const { error: uploadError } = await supabase.storage.from('documents').upload(path, file, { contentType: file.type })
  if (uploadError) throw new Error(uploadError.message)

  const { data: userData } = await supabase.auth.getUser()
  unwrap(
    await supabase.from('documents').insert({
      entity_type: entityType,
      entity_id: Number(entityId),
      doc_type: docType,
      filename: file.name,
      storage_path: path,
      content_type: file.type || 'application/octet-stream',
      size_bytes: file.size,
      uploaded_by: userData.user?.id,
    }),
  )
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
  const rows = unwrap<Row[]>(
    await supabase
      .from('activity_log')
      .select('*, user:profiles(username, full_name)')
      .eq('entity_type', entityType)
      .eq('entity_id', entityId)
      .order('created_at', { ascending: false })
      .limit(200),
  )
  return rows.map((row) => {
    const user = row.user as { username: string; full_name: string } | null
    return { ...(row as unknown as Activity), user_name: user ? user.full_name || user.username : null }
  })
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
  return unwrap(await supabase.rpc('weekly_report', { p_week_of: weekOf }))
}

export async function dashboardSummary(): Promise<DashboardSummary> {
  return unwrap(await supabase.rpc('dashboard_summary'))
}

export async function globalSearch(q: string): Promise<SearchResults> {
  return unwrap(await supabase.rpc('global_search', { q }))
}

// ---------- Users (admin edge function) ----------

async function invokeAdminUsers<T>(options: { method: 'GET' | 'POST' | 'PATCH'; body?: Row }): Promise<T> {
  const { data, error } = await supabase.functions.invoke('admin-users', options)
  if (error) {
    // FunctionsHttpError carries the response; surface the server's message.
    const context = (error as { context?: Response }).context
    if (context) {
      const body = await context.json().catch(() => null)
      if (body?.error) throw new Error(body.error)
    }
    throw new Error(error.message)
  }
  return data as T
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

export interface ExtractResult {
  raw_text: string
  fields: {
    customer_name?: string | null
    pickup_address?: string | null
    pickup_time?: string | null
    delivery_address?: string | null
    delivery_time?: string | null
    rate?: number | null
    special_terms?: string | null
  } | null
  error: string | null
}

export async function extractPdf(file: File): Promise<ExtractResult> {
  const form = new FormData()
  form.append('file', file)
  const { data, error } = await supabase.functions.invoke('extract-pdf', { body: form })
  if (error) throw new Error(error.message)
  return data as ExtractResult
}

export async function calculateDistance(origin: string, destination: string): Promise<{ miles: number | null; available: boolean }> {
  const { data, error } = await supabase.functions.invoke('distance', { body: { origin, destination } })
  if (error) throw new Error(error.message)
  return data as { miles: number | null; available: boolean }
}

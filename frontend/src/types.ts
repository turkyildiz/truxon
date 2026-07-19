export type Role = 'admin' | 'dispatcher' | 'driver' | 'accountant' | 'maintenance'

export interface Profile {
  id: string
  username: string
  full_name: string
  role: Role
  is_active: boolean
  email?: string
}

export interface Customer {
  id: number
  company_name: string
  contact_person: string
  phone: string
  email: string
  fax: string
  toll_free: string
  secondary_contact: string
  secondary_phone: string
  secondary_email: string
  billing_address: string
  payment_terms: string
  notes: string
  is_active: boolean
}

export interface Driver {
  id: number
  full_name: string
  phone: string
  email: string
  address: string
  city: string
  state: string
  license_number: string
  license_expiration: string | null
  date_of_birth: string | null
  hire_date: string | null
  pay_per_mile: number
  empty_miles_paid: boolean
  pay_per_empty_mile: number
  notes: string
  status: 'active' | 'inactive' | 'terminated'
  /** Linked auth profile (role must be driver). */
  user_id?: string | null
}

export interface Equipment {
  id: number
  unit_number: string
  make: string
  model: string
  year: number | null
  vin: string
  plate_number: string
  plate_expiry: string | null
  in_service_date: string | null
  out_of_service_date: string | null
  monthly_cost: number
  notes: string
  status: 'available' | 'in_use' | 'maintenance' | 'retired'
}

export interface MaintenanceRecord {
  id: number
  equipment_type: 'truck' | 'trailer'
  truck_id: number | null
  trailer_id: number | null
  date_completed: string | null
  description: string
  cost: number
  technician_shop: string
  equipment_unit: string | null
}

export type LoadStatus = 'pending' | 'assigned' | 'in_transit' | 'delivered' | 'completed' | 'billed' | 'cancelled'

/** The linear workflow progression — 'cancelled' sits outside it (cancel/un-cancel RPCs only). */
export const LOAD_STATUSES: LoadStatus[] = ['pending', 'assigned', 'in_transit', 'delivered', 'completed', 'billed']

export interface Load {
  id: number
  load_number: string
  reference_number: string
  pickup_number: string
  delivery_number: string
  equipment_type: string
  empty_miles: number
  customer_id: number
  customer_name: string | null
  status: LoadStatus
  pickup_address: string
  pickup_time: string | null
  delivery_address: string
  delivery_time: string | null
  driver_id: number | null
  driver_name: string | null
  truck_id: number | null
  truck_unit: string | null
  trailer_id: number | null
  trailer_unit: string | null
  rate: number
  miles: number
  rate_per_mile: number | null
  special_terms: string
  notes: string
  cancel_reason: string
  invoice_id: number | null
  created_at: string
}

export interface Invoice {
  id: number
  invoice_number: string
  customer_id: number
  customer_name: string | null
  invoice_date: string
  due_date: string | null
  total: number
  status: 'draft' | 'sent' | 'paid' | 'void'
  load_count: number
}

export interface DocumentMeta {
  id: number
  doc_type: string
  filename: string
  storage_path: string
  content_type: string
  size_bytes: number
  uploaded_at: string
}

export interface Activity {
  id: number
  action: string
  detail: string
  created_at: string
  user_name: string | null
}

export interface WeeklyRow {
  key_id: number
  name: string
  loads: number
  miles: number
  empty_miles?: number | null
  revenue: number
  avg_rate_per_mile: number | null
  driver_pay?: number | null
}

export interface WeeklyReport {
  week_start: string
  week_end: string
  by_truck: WeeklyRow[]
  by_driver: WeeklyRow[]
  totals: { loads: number; miles: number; revenue: number; avg_rate_per_mile: number | null }
}

export interface DashboardActiveLoad {
  id: number
  load_number: string
  status: LoadStatus
  pickup_address: string
  pickup_time: string | null
  delivery_address: string
  delivery_time: string | null
  customer_name: string
  driver_name: string | null
}

export interface TrendPoint {
  label: string
  revenue: number
  miles: number
  empty_miles: number
  loads: number
}

export interface DashboardSummary {
  week_revenue: number
  week_miles: number
  week_loads: number
  week_avg_rate_per_mile: number | null
  prev_week: { revenue: number; miles: number; loads: number; avg_rate_per_mile: number | null }
  prev_year_week: { revenue: number; miles: number; loads: number; avg_rate_per_mile: number | null }
  available_trucks: number
  active_drivers: number
  status_counts: Record<string, number>
  revenue_by_day: { day: string; revenue: number }[]
  trend_weekly: TrendPoint[]
  trend_monthly: TrendPoint[]
  top_customers: { name: string; revenue: number; loads: number }[]
  driver_perf: { name: string; miles: number; revenue: number; loads: number }[]
  expiring_licenses: { id: number; full_name: string; license_expiration: string }[]
  active_loads: DashboardActiveLoad[]
}

export interface SearchResults {
  loads: { id: number; label: string }[]
  customers: { id: number; label: string }[]
  drivers: { id: number; label: string }[]
  trucks: { id: number; label: string }[]
}

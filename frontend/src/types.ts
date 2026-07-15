export type Role = 'admin' | 'dispatcher' | 'driver' | 'accountant' | 'maintenance'

export interface User {
  id: number
  username: string
  full_name: string
  role: Role
  is_active: boolean
}

export interface Customer {
  id: number
  company_name: string
  contact_person: string
  phone: string
  email: string
  billing_address: string
  payment_terms: string
  notes: string
  is_active: boolean
}

export interface Driver {
  id: number
  full_name: string
  license_number: string
  license_expiration: string | null
  date_of_birth: string | null
  hire_date: string | null
  pay_per_mile: string
  status: 'active' | 'inactive' | 'terminated'
}

export interface Equipment {
  id: number
  unit_number: string
  make: string
  model: string
  year: number | null
  vin: string
  in_service_date: string | null
  out_of_service_date: string | null
  monthly_cost: string
  status: 'available' | 'in_use' | 'maintenance' | 'retired'
}

export interface MaintenanceRecord {
  id: number
  equipment_type: 'truck' | 'trailer'
  truck_id: number | null
  trailer_id: number | null
  date_completed: string | null
  description: string
  cost: string
  technician_shop: string
  equipment_unit: string | null
}

export type LoadStatus = 'pending' | 'assigned' | 'in_transit' | 'delivered' | 'completed' | 'billed'

export const LOAD_STATUSES: LoadStatus[] = ['pending', 'assigned', 'in_transit', 'delivered', 'completed', 'billed']

export interface Load {
  id: number
  load_number: string
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
  rate: string
  miles: string
  rate_per_mile: string | null
  special_terms: string
  notes: string
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
  total: string
  status: 'draft' | 'sent' | 'paid'
  load_count: number
}

export interface DocumentMeta {
  id: number
  doc_type: string
  filename: string
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
  miles: string
  revenue: string
  avg_rate_per_mile: string | null
  driver_pay: string | null
}

export interface WeeklyReport {
  week_start: string
  week_end: string
  by_truck: WeeklyRow[]
  by_driver: WeeklyRow[]
  totals: WeeklyRow
}

export interface DashboardSummary {
  active_loads: Load[]
  week_revenue: string
  week_miles: string
  week_loads: number
  week_avg_rate_per_mile: string | null
  available_trucks: number
  active_drivers: number
  status_counts: Record<string, number>
  revenue_by_day: { day: string; revenue: number }[]
  expiring_licenses: Driver[]
}

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
  do_not_use: boolean
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
  medical_card_number: string | null
  medical_card_expiry: string | null
  drug_consortium: string | null
  drug_pool_enrolled_on: string | null
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
  monthly_cost: number | null
  ownership: 'owned' | 'financed' | 'leased' | null
  monthly_payment: number | null
  purchase_price: number | null
  purchase_date: string | null
  notes: string
  status: 'available' | 'in_use' | 'maintenance' | 'retired'
}

export type MaintenanceServiceType =
  | 'pm_service' | 'oil_lube' | 'tires' | 'brakes' | 'engine' | 'drivetrain'
  | 'electrical' | 'cooling' | 'aftertreatment' | 'dot_inspection' | 'bodywork'
  | 'roadside' | 'other'

export type MaintenanceStatus = 'scheduled' | 'in_progress' | 'completed' | 'cancelled'

/** Human labels for the service-type enum (used in dropdowns and tables). */
export const SERVICE_TYPE_LABELS: Record<MaintenanceServiceType, string> = {
  pm_service: 'PM Service', oil_lube: 'Oil & Lube', tires: 'Tires', brakes: 'Brakes',
  engine: 'Engine', drivetrain: 'Drivetrain', electrical: 'Electrical', cooling: 'Cooling',
  aftertreatment: 'Aftertreatment/DEF', dot_inspection: 'DOT Inspection', bodywork: 'Body/Trailer',
  roadside: 'Roadside', other: 'Other',
}

export interface MaintenanceRecord {
  id: number
  equipment_type: 'truck' | 'trailer'
  truck_id: number | null
  trailer_id: number | null
  date_completed: string | null
  scheduled_date: string | null
  service_type: MaintenanceServiceType
  status: MaintenanceStatus
  is_planned: boolean
  odometer: number | null
  vendor_id: number | null
  invoice_ref: string
  pm_program_id: number | null
  description: string
  cost: number
  technician_shop: string
  source: 'manual' | 'email' | 'api'
  needs_review: boolean
  equipment_unit: string | null
}

export interface MaintenanceVendor {
  id: number
  name: string
  phone: string
  city: string
  state: string
  specialty: string
  notes: string
  is_active: boolean
}

export interface PmProgram {
  id: number
  name: string
  applies_to: 'truck' | 'trailer' | 'all'
  service_type: MaintenanceServiceType
  interval_miles: number | null
  interval_days: number | null
  is_active: boolean
  notes: string
}

export type DueStatus = 'overdue' | 'due_soon' | 'ok' | 'never_serviced' | 'unknown'

export interface MaintenanceAlert {
  kind: 'pm' | 'plate' | 'open_wo'
  severity: 'overdue' | 'due_soon' | 'info'
  equipment_type: string
  unit_id: number | null
  unit_number: string | null
  label: string
  detail: string
  due_date: string | null
  category: string
}

export interface MaintenanceDueRow {
  equipment_type: string
  unit_id: number
  unit_number: string
  program_id: number
  program_name: string
  service_type: string
  interval_miles: number | null
  interval_days: number | null
  last_service_date: string | null
  last_service_odometer: number | null
  current_odometer: number | null
  miles_since: number | null
  days_since: number | null
  miles_remaining: number | null
  days_remaining: number | null
  due_status: DueStatus
}

export interface MaintenanceByTruckRow {
  truck_id: number
  unit_number: string
  events: number
  planned_cost: number
  reactive_cost: number
  total_cost: number
  window_miles: number | null
  cpm: number | null
}

export interface MaintenanceByVendorRow {
  vendor: string
  events: number
  total_cost: number
  planned_cost: number
}

export interface FleetOdometerRow {
  truck_id: number
  unit_number: string
  odometer: number | null
  reading_date: string | null
}

export interface MaintenanceSummary {
  window: { start: string; end: string }
  events: number
  total_cost: number
  planned_cost: number
  reactive_cost: number
  planned_pct: number | null
  units_in_shop: number
  deadlined_tractor_pct: number | null
  open_work_orders: number
  pm_compliance_pct: number | null
  by_service: { service_type: string; cost: number; events: number }[]
  top_units: { unit_number: string; total_cost: number; cpm: number | null }[]
}

export interface MaintenanceCpm {
  window: { start: string; end: string }
  total_miles: number
  maintenance_cost: number
  maintenance_cpm: number | null
  tire_cost: number
  tire_cpm: number | null
  planned_cost: number
  reactive_cost: number
  planned_pct: number | null
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
  awaiting_paperwork: boolean
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
  /** 'qbo' rows are mirrored from QuickBooks (books of record in transition mode) */
  source: 'truxon' | 'qbo'
  qbo_doc_number: string | null
  qbo_balance: number | null
  paid_at: string | null
  sent_at: string | null
  sent_to: string | null
  factored_at: string | null
  factoring_fee: number | null
  factor_name: string | null
}

// ── Accounting module ────────────────────────────────────────────────────────

export interface AcctSummary {
  ar_total: number
  ar_past_due: number
  past_due_count: number
  open_count: number
  dso: number | null
  avg_days_to_pay: number | null
  unbilled_total: number
  unbilled_count: number
  mtd_billed: number
  mtd_collected: number
}

export interface AgingRow {
  customer_id: number
  customer_name: string
  current_due: number
  d1_30: number
  d31_60: number
  d61_90: number
  d90_plus: number
  total: number
  invoice_count: number
}

export interface UnbilledLoad {
  load_id: number
  load_number: string
  customer_id: number
  customer_name: string
  delivered_at: string | null
  days_unbilled: number
  rate: number
}

export interface RevenueMonth {
  month: string
  billed: number
  collected: number
}

export interface CustomerRevenue {
  customer_id: number
  customer_name: string
  billed: number
  share_pct: number | null
  open_balance: number
  past_due: number
  avg_days_to_pay: number | null
  invoice_count: number
}

export interface MarginMonth {
  month: string
  revenue: number
  fuel: number
  tolls: number
  maintenance: number
  margin: number
  operating_ratio: number | null
}

export interface InvoicePayment {
  id: number
  invoice_id: number
  amount: number
  method: string
  reference: string | null
  notes: string | null
  received_at: string
}

// ── GL mirror (full P&L from the books) ─────────────────────────────────────

export interface GlPnlMonth {
  month: string
  income: number
  cogs: number
  gross_profit: number
  gross_margin_pct: number | null
  opex: number
  other_net: number
  net_income: number
  net_margin_pct: number | null
  operating_ratio: number | null
}

export interface GlExpenseRow {
  account: string
  grp: string
  total: number
  monthly_avg: number
  pct_of_revenue: number | null
}

export interface GlBreakevenMonth {
  month: string
  revenue: number
  total_costs: number
  miles: number
  rpm_actual: number | null
  rpm_breakeven: number | null
  cushion_pct: number | null
}

export interface CfoSnapshot {
  as_of: string | null
  cash: number | null
  ap: number | null
  working_capital: number | null
  working_capital_pct_revenue: number | null
  current_ratio: number | null
  dpo: number | null
  days_of_cash: number | null
  interest_coverage: number | null
  overhead_per_tractor_month: number | null
  total_cost_of_risk_12m: number | null
  revenue_12m: number | null
  operating_ratio_12m: number | null
  equipment_gap_12m: number | null
  operating_ratio_equip_adj: number | null
}

/** QuickBooks connection + sync status card (admin only). */
export interface QboStatus {
  connected: boolean
  realm_id: string | null
  connected_at: string | null
  backfilled: boolean
  last_pull_at: string | null
  last_error: string | null
  last_result: Record<string, number> | null
  qbo_invoices: number
  qbo_open_balance: number
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
  // by_truck only:
  fuel_cost?: number | null
  fuel_gallons?: number | null
  mpg?: number | null
  net_after_fuel?: number | null
}

export interface WeeklyReport {
  week_start: string
  week_end: string
  week_number: number
  week_year: number
  week_label: string
  by_truck: WeeklyRow[]
  by_driver: WeeklyRow[]
  totals: {
    loads: number
    miles: number
    revenue: number
    avg_rate_per_mile: number | null
    fuel_cost?: number | null
    fuel_gallons?: number | null
    net_after_fuel?: number | null
    fuel_pct_of_revenue?: number | null
  }
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
  week?: string
  range?: string
  revenue: number
  miles: number
  empty_miles: number
  loads: number
}

export interface DashboardSummary {
  week_number: number
  week_label: string
  week_start: string
  week_revenue: number
  week_miles: number
  week_loads: number
  week_avg_rate_per_mile: number | null
  prev_week: { revenue: number; miles: number; loads: number; avg_rate_per_mile: number | null }
  prev_year_week: { label: string; revenue: number; miles: number; loads: number; avg_rate_per_mile: number | null }
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

export interface FuelByTruckRow {
  truck_id: number
  unit_number: string
  transactions: number
  gallons: number
  spend: number
}

export interface FuelIftaRow {
  jurisdiction: string
  transactions: number
  gallons: number
  spend: number
}

export interface TollByTruckRow {
  truck_id: number
  unit_number: string
  tolls: number
  violations: number
  spend: number
}

export interface TollByAgencyRow {
  jurisdiction: string
  agency: string
  tolls: number
  spend: number
}

export interface FuelImportResult {
  parsed: number
  inserted: number
  updated: number
  received: number
  /** Count of imported rows whose vehicle didn't match a Truxon truck. */
  unmatched_trucks: number
}

export interface SearchResults {
  loads: { id: number; label: string }[]
  customers: { id: number; label: string }[]
  drivers: { id: number; label: string }[]
  trucks: { id: number; label: string }[]
  documents: { id: number; label: string; entity_type: string; entity_id: number }[]
}

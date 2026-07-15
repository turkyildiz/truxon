"""Pydantic request/response schemas for the API."""

from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import (
    DriverStatus,
    EquipmentStatus,
    EquipmentType,
    InvoiceStatus,
    LoadStatus,
    UserRole,
)


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# ---------- Auth / Users ----------

class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserOut(ORMModel):
    id: int
    username: str
    full_name: str
    role: UserRole
    is_active: bool


class UserCreate(BaseModel):
    username: str = Field(min_length=3, max_length=50)
    full_name: str = ""
    password: str = Field(min_length=8)
    role: UserRole


class UserUpdate(BaseModel):
    full_name: str | None = None
    password: str | None = Field(default=None, min_length=8)
    role: UserRole | None = None
    is_active: bool | None = None


# ---------- Customers ----------

class CustomerBase(BaseModel):
    company_name: str = Field(min_length=1, max_length=200)
    contact_person: str = ""
    phone: str = ""
    email: str = ""
    billing_address: str = ""
    payment_terms: str = "Net 30"
    notes: str = ""
    is_active: bool = True


class CustomerCreate(CustomerBase):
    pass


class CustomerUpdate(BaseModel):
    company_name: str | None = None
    contact_person: str | None = None
    phone: str | None = None
    email: str | None = None
    billing_address: str | None = None
    payment_terms: str | None = None
    notes: str | None = None
    is_active: bool | None = None


class CustomerOut(ORMModel, CustomerBase):
    id: int
    created_at: datetime


# ---------- Drivers ----------

class DriverBase(BaseModel):
    full_name: str = Field(min_length=1, max_length=120)
    license_number: str = ""
    license_expiration: date | None = None
    date_of_birth: date | None = None
    hire_date: date | None = None
    pay_per_mile: Decimal = Decimal("0")
    status: DriverStatus = DriverStatus.ACTIVE


class DriverCreate(DriverBase):
    pass


class DriverUpdate(BaseModel):
    full_name: str | None = None
    license_number: str | None = None
    license_expiration: date | None = None
    date_of_birth: date | None = None
    hire_date: date | None = None
    pay_per_mile: Decimal | None = None
    status: DriverStatus | None = None


class DriverOut(ORMModel, DriverBase):
    id: int


# ---------- Trucks / Trailers ----------

class EquipmentBase(BaseModel):
    unit_number: str = Field(min_length=1, max_length=30)
    make: str = ""
    model: str = ""
    year: int | None = None
    vin: str = ""
    in_service_date: date | None = None
    out_of_service_date: date | None = None
    monthly_cost: Decimal = Decimal("0")
    status: EquipmentStatus = EquipmentStatus.AVAILABLE


class EquipmentCreate(EquipmentBase):
    pass


class EquipmentUpdate(BaseModel):
    unit_number: str | None = None
    make: str | None = None
    model: str | None = None
    year: int | None = None
    vin: str | None = None
    in_service_date: date | None = None
    out_of_service_date: date | None = None
    monthly_cost: Decimal | None = None
    status: EquipmentStatus | None = None


class EquipmentOut(ORMModel, EquipmentBase):
    id: int


# ---------- Maintenance ----------

class MaintenanceBase(BaseModel):
    equipment_type: EquipmentType
    truck_id: int | None = None
    trailer_id: int | None = None
    date_completed: date | None = None
    description: str = ""
    cost: Decimal = Decimal("0")
    technician_shop: str = ""


class MaintenanceCreate(MaintenanceBase):
    pass


class MaintenanceUpdate(BaseModel):
    equipment_type: EquipmentType | None = None
    truck_id: int | None = None
    trailer_id: int | None = None
    date_completed: date | None = None
    description: str | None = None
    cost: Decimal | None = None
    technician_shop: str | None = None


class MaintenanceOut(ORMModel, MaintenanceBase):
    id: int
    created_at: datetime
    equipment_unit: str | None = None


# ---------- Loads ----------

class LoadBase(BaseModel):
    customer_id: int
    pickup_address: str = ""
    pickup_time: datetime | None = None
    delivery_address: str = ""
    delivery_time: datetime | None = None
    driver_id: int | None = None
    truck_id: int | None = None
    trailer_id: int | None = None
    rate: Decimal = Decimal("0")
    miles: Decimal = Decimal("0")
    special_terms: str = ""
    notes: str = ""


class LoadCreate(LoadBase):
    pass


class LoadUpdate(BaseModel):
    customer_id: int | None = None
    pickup_address: str | None = None
    pickup_time: datetime | None = None
    delivery_address: str | None = None
    delivery_time: datetime | None = None
    driver_id: int | None = None
    truck_id: int | None = None
    trailer_id: int | None = None
    rate: Decimal | None = None
    miles: Decimal | None = None
    special_terms: str | None = None
    notes: str | None = None


class LoadStatusUpdate(BaseModel):
    status: LoadStatus


class LoadOut(ORMModel, LoadBase):
    id: int
    load_number: str
    status: LoadStatus
    rate_per_mile: Decimal | None = None
    invoice_id: int | None = None
    customer_name: str | None = None
    driver_name: str | None = None
    truck_unit: str | None = None
    trailer_unit: str | None = None
    created_at: datetime


# ---------- Documents / Activity ----------

class DocumentOut(ORMModel):
    id: int
    entity_type: str
    entity_id: int
    doc_type: str
    filename: str
    content_type: str
    size_bytes: int
    uploaded_at: datetime


class NoteCreate(BaseModel):
    detail: str = Field(min_length=1)


class ActivityOut(ORMModel):
    id: int
    entity_type: str
    entity_id: int
    action: str
    detail: str
    created_at: datetime
    user_name: str | None = None


# ---------- Invoices ----------

class InvoiceCreate(BaseModel):
    customer_id: int
    load_ids: list[int] = Field(min_length=1)
    due_date: datetime | None = None


class InvoiceOut(ORMModel):
    id: int
    invoice_number: str
    customer_id: int
    customer_name: str | None = None
    invoice_date: datetime
    due_date: datetime | None
    total: Decimal
    status: InvoiceStatus
    load_count: int = 0


# ---------- Reports / Dashboard ----------

class WeeklyRow(BaseModel):
    key_id: int
    name: str
    loads: int
    miles: Decimal
    revenue: Decimal
    avg_rate_per_mile: Decimal | None = None
    driver_pay: Decimal | None = None  # only for driver rows


class WeeklyReport(BaseModel):
    week_start: date
    week_end: date
    by_truck: list[WeeklyRow]
    by_driver: list[WeeklyRow]
    totals: WeeklyRow


class DashboardSummary(BaseModel):
    active_loads: list[LoadOut]
    week_revenue: Decimal
    week_miles: Decimal
    week_loads: int
    week_avg_rate_per_mile: Decimal | None
    available_trucks: int
    active_drivers: int
    status_counts: dict[str, int]
    revenue_by_day: list[dict]
    expiring_licenses: list[DriverOut]

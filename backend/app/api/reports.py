"""Weekly accounting reports, dashboard summary, and global search."""

from collections import defaultdict
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal

from fastapi import APIRouter, Depends
from sqlalchemy import or_
from sqlalchemy.orm import Session

from app import schemas
from app.api.loads import to_out as load_to_out
from app.core.deps import get_current_user, require_roles
from app.db import get_db
from app.models import (
    Customer,
    Driver,
    DriverStatus,
    EquipmentStatus,
    Load,
    LoadStatus,
    Truck,
    User,
    UserRole,
)

router = APIRouter(prefix="/api", tags=["reports"])

REVENUE_STATUSES = (LoadStatus.COMPLETED, LoadStatus.BILLED)


def week_bounds(anchor: date) -> tuple[date, date]:
    """Monday-through-Sunday week containing the anchor date."""
    start = anchor - timedelta(days=anchor.weekday())
    return start, start + timedelta(days=6)


def _week_loads(db: Session, start: date, end: date) -> list[Load]:
    """Loads counted for a week: delivered within the week and completed/billed."""
    start_dt = datetime.combine(start, time.min, tzinfo=timezone.utc)
    end_dt = datetime.combine(end, time.max, tzinfo=timezone.utc)
    return (
        db.query(Load)
        .filter(Load.status.in_(REVENUE_STATUSES))
        .filter(Load.delivery_time >= start_dt, Load.delivery_time <= end_dt)
        .all()
    )


def _aggregate(loads: list[Load], key: str) -> list[schemas.WeeklyRow]:
    groups: dict[int, list[Load]] = defaultdict(list)
    for load in loads:
        entity_id = getattr(load, f"{key}_id")
        if entity_id:
            groups[entity_id].append(load)

    rows = []
    for entity_id, group in groups.items():
        miles = sum((Decimal(l.miles) for l in group), Decimal("0"))
        revenue = sum((Decimal(l.rate) for l in group), Decimal("0"))
        entity = getattr(group[0], key)
        row = schemas.WeeklyRow(
            key_id=entity_id,
            name=entity.full_name if key == "driver" else entity.unit_number,
            loads=len(group),
            miles=miles,
            revenue=revenue,
            avg_rate_per_mile=(revenue / miles).quantize(Decimal("0.01")) if miles else None,
        )
        if key == "driver":
            row.driver_pay = (miles * Decimal(entity.pay_per_mile)).quantize(Decimal("0.01"))
        rows.append(row)
    return sorted(rows, key=lambda r: r.revenue, reverse=True)


@router.get(
    "/reports/weekly",
    response_model=schemas.WeeklyReport,
    dependencies=[Depends(require_roles(UserRole.ACCOUNTANT, UserRole.DISPATCHER))],
)
def weekly_report(week_of: date | None = None, db: Session = Depends(get_db)):
    start, end = week_bounds(week_of or datetime.now(timezone.utc).date())
    loads = _week_loads(db, start, end)
    miles = sum((Decimal(l.miles) for l in loads), Decimal("0"))
    revenue = sum((Decimal(l.rate) for l in loads), Decimal("0"))
    totals = schemas.WeeklyRow(
        key_id=0,
        name="TOTAL",
        loads=len(loads),
        miles=miles,
        revenue=revenue,
        avg_rate_per_mile=(revenue / miles).quantize(Decimal("0.01")) if miles else None,
    )
    return schemas.WeeklyReport(
        week_start=start,
        week_end=end,
        by_truck=_aggregate(loads, "truck"),
        by_driver=_aggregate(loads, "driver"),
        totals=totals,
    )


@router.get("/dashboard", response_model=schemas.DashboardSummary)
def dashboard(db: Session = Depends(get_db), _: User = Depends(get_current_user)):
    today = datetime.now(timezone.utc).date()
    start, end = week_bounds(today)
    week_loads = _week_loads(db, start, end)
    miles = sum((Decimal(l.miles) for l in week_loads), Decimal("0"))
    revenue = sum((Decimal(l.rate) for l in week_loads), Decimal("0"))

    active = (
        db.query(Load)
        .filter(Load.status.in_((LoadStatus.ASSIGNED, LoadStatus.IN_TRANSIT)))
        .order_by(Load.pickup_time)
        .limit(25)
        .all()
    )

    status_counts = {s.value: 0 for s in LoadStatus}
    for load_status, in db.query(Load.status).all():
        status_counts[load_status.value] += 1

    revenue_by_day = []
    for offset in range(7):
        day = start + timedelta(days=offset)
        day_total = sum(
            (Decimal(l.rate) for l in week_loads if l.delivery_time and l.delivery_time.date() == day),
            Decimal("0"),
        )
        revenue_by_day.append({"day": day.strftime("%a"), "revenue": float(day_total)})

    soon = today + timedelta(days=30)
    expiring = (
        db.query(Driver)
        .filter(Driver.status == DriverStatus.ACTIVE)
        .filter(Driver.license_expiration.isnot(None), Driver.license_expiration <= soon)
        .all()
    )

    return schemas.DashboardSummary(
        active_loads=[load_to_out(l) for l in active],
        week_revenue=revenue,
        week_miles=miles,
        week_loads=len(week_loads),
        week_avg_rate_per_mile=(revenue / miles).quantize(Decimal("0.01")) if miles else None,
        available_trucks=db.query(Truck).filter(Truck.status == EquipmentStatus.AVAILABLE).count(),
        active_drivers=db.query(Driver).filter(Driver.status == DriverStatus.ACTIVE).count(),
        status_counts=status_counts,
        revenue_by_day=revenue_by_day,
        expiring_licenses=expiring,
    )


@router.get("/search")
def global_search(q: str, db: Session = Depends(get_db), _: User = Depends(get_current_user)):
    like = f"%{q}%"
    loads = (
        db.query(Load)
        .filter(or_(Load.load_number.ilike(like), Load.pickup_address.ilike(like), Load.delivery_address.ilike(like)))
        .limit(10)
        .all()
    )
    customers = db.query(Customer).filter(Customer.company_name.ilike(like)).limit(10).all()
    drivers = db.query(Driver).filter(Driver.full_name.ilike(like)).limit(10).all()
    trucks = db.query(Truck).filter(Truck.unit_number.ilike(like)).limit(10).all()
    return {
        "loads": [{"id": l.id, "label": f"{l.load_number} — {l.customer.company_name if l.customer else ''}"} for l in loads],
        "customers": [{"id": c.id, "label": c.company_name} for c in customers],
        "drivers": [{"id": d.id, "label": d.full_name} for d in drivers],
        "trucks": [{"id": t.id, "label": t.unit_number} for t in trucks],
    }

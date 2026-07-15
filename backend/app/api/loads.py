from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import or_
from sqlalchemy.orm import Session

from app import schemas
from app.api.crud_helpers import apply_update, get_or_404
from app.core.deps import get_current_user, require_roles
from app.db import get_db
from app.models import (
    LOAD_STATUS_ORDER,
    Customer,
    EquipmentStatus,
    Load,
    LoadStatus,
    Trailer,
    Truck,
    User,
    UserRole,
)
from app.services.audit import log_activity

router = APIRouter(
    prefix="/api/loads",
    tags=["loads"],
    dependencies=[Depends(require_roles(UserRole.DISPATCHER, UserRole.ACCOUNTANT))],
)


def next_load_number(db: Session) -> str:
    """Sequential load numbers like LD-2026-0001, per year."""
    year = datetime.now(timezone.utc).year
    prefix = f"LD-{year}-"
    last = (
        db.query(Load.load_number)
        .filter(Load.load_number.like(f"{prefix}%"))
        .order_by(Load.load_number.desc())
        .first()
    )
    seq = int(last[0].removeprefix(prefix)) + 1 if last else 1
    return f"{prefix}{seq:04d}"


def to_out(load: Load) -> schemas.LoadOut:
    out = schemas.LoadOut.model_validate(load)
    out.customer_name = load.customer.company_name if load.customer else None
    out.driver_name = load.driver.full_name if load.driver else None
    out.truck_unit = load.truck.unit_number if load.truck else None
    out.trailer_unit = load.trailer.unit_number if load.trailer else None
    return out


def _sync_equipment_status(db: Session, load: Load) -> None:
    """Trucks/trailers show In Use while their load is active."""
    active = load.status in (LoadStatus.ASSIGNED, LoadStatus.IN_TRANSIT)
    for model, item_id in ((Truck, load.truck_id), (Trailer, load.trailer_id)):
        if not item_id:
            continue
        item = db.get(model, item_id)
        if not item or item.status in (EquipmentStatus.MAINTENANCE, EquipmentStatus.RETIRED):
            continue
        item.status = EquipmentStatus.IN_USE if active else EquipmentStatus.AVAILABLE


@router.get("", response_model=list[schemas.LoadOut])
def list_loads(
    q: str = "",
    status: LoadStatus | None = None,
    customer_id: int | None = None,
    driver_id: int | None = None,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    limit: int = 200,
    db: Session = Depends(get_db),
):
    query = db.query(Load)
    if status:
        query = query.filter(Load.status == status)
    if customer_id:
        query = query.filter(Load.customer_id == customer_id)
    if driver_id:
        query = query.filter(Load.driver_id == driver_id)
    if date_from:
        query = query.filter(Load.pickup_time >= date_from)
    if date_to:
        query = query.filter(Load.pickup_time <= date_to)
    if q:
        like = f"%{q}%"
        query = query.filter(
            or_(Load.load_number.ilike(like), Load.pickup_address.ilike(like), Load.delivery_address.ilike(like))
        )
    loads = query.order_by(Load.created_at.desc()).limit(min(limit, 500)).all()
    return [to_out(l) for l in loads]


@router.post("", response_model=schemas.LoadOut, status_code=201)
def create_load(
    payload: schemas.LoadCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    get_or_404(db, Customer, payload.customer_id)
    load = Load(**payload.model_dump(), load_number=next_load_number(db))
    if load.driver_id and load.truck_id:
        load.status = LoadStatus.ASSIGNED
    db.add(load)
    db.flush()
    _sync_equipment_status(db, load)
    log_activity(db, entity_type="load", entity_id=load.id, user=user, action="created",
                 detail=f"Load {load.load_number} created with status {load.status.value}")
    db.commit()
    db.refresh(load)
    return to_out(load)


@router.get("/{load_id}", response_model=schemas.LoadOut)
def get_load(load_id: int, db: Session = Depends(get_db)):
    return to_out(get_or_404(db, Load, load_id))


@router.patch("/{load_id}", response_model=schemas.LoadOut)
def update_load(
    load_id: int,
    payload: schemas.LoadUpdate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    load = get_or_404(db, Load, load_id)
    if load.status == LoadStatus.BILLED:
        raise HTTPException(status_code=409, detail="Billed loads are locked; unbill first")
    apply_update(db, load, payload, entity_type="load", user=user)
    # Auto-advance a pending load once fully assigned.
    if load.status == LoadStatus.PENDING and load.driver_id and load.truck_id:
        load.status = LoadStatus.ASSIGNED
        log_activity(db, entity_type="load", entity_id=load.id, user=user,
                     action="status_changed", detail="pending → assigned (auto)")
    _sync_equipment_status(db, load)
    db.commit()
    db.refresh(load)
    return to_out(load)


@router.post("/{load_id}/status", response_model=schemas.LoadOut)
def change_status(
    load_id: int,
    payload: schemas.LoadStatusUpdate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    load = get_or_404(db, Load, load_id)
    current_idx = LOAD_STATUS_ORDER.index(load.status)
    new_idx = LOAD_STATUS_ORDER.index(payload.status)
    if new_idx == current_idx:
        return to_out(load)
    # Forward one step at a time; backward one step for corrections.
    if new_idx not in (current_idx + 1, current_idx - 1):
        raise HTTPException(
            status_code=409,
            detail=f"Cannot go from {load.status.value} to {payload.status.value}",
        )
    if payload.status == LoadStatus.ASSIGNED and not (load.driver_id and load.truck_id):
        raise HTTPException(status_code=409, detail="Assign a driver and truck first")
    if payload.status == LoadStatus.BILLED and not load.invoice_id:
        raise HTTPException(status_code=409, detail="Generate an invoice to mark a load billed")
    old = load.status
    load.status = payload.status
    _sync_equipment_status(db, load)
    log_activity(db, entity_type="load", entity_id=load.id, user=user,
                 action="status_changed", detail=f"{old.value} → {payload.status.value}")
    db.commit()
    db.refresh(load)
    return to_out(load)

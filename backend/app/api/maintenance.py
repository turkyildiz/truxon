from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app import schemas
from app.api.crud_helpers import apply_update, get_or_404
from app.core.deps import get_current_user, require_roles
from app.db import get_db
from app.models import EquipmentType, MaintenanceRecord, User, UserRole
from app.services.audit import log_activity

router = APIRouter(
    prefix="/api/maintenance",
    tags=["maintenance"],
    dependencies=[Depends(require_roles(UserRole.MAINTENANCE, UserRole.ACCOUNTANT, UserRole.DISPATCHER))],
)


def _to_out(rec: MaintenanceRecord) -> schemas.MaintenanceOut:
    out = schemas.MaintenanceOut.model_validate(rec)
    equipment = rec.truck if rec.equipment_type == EquipmentType.TRUCK else rec.trailer
    out.equipment_unit = equipment.unit_number if equipment else None
    return out


def _validate_link(payload) -> None:
    if payload.equipment_type == EquipmentType.TRUCK and not payload.truck_id:
        raise HTTPException(status_code=422, detail="truck_id required for truck maintenance")
    if payload.equipment_type == EquipmentType.TRAILER and not payload.trailer_id:
        raise HTTPException(status_code=422, detail="trailer_id required for trailer maintenance")


@router.get("", response_model=list[schemas.MaintenanceOut])
def list_records(
    equipment_type: EquipmentType | None = None,
    truck_id: int | None = None,
    trailer_id: int | None = None,
    db: Session = Depends(get_db),
):
    query = db.query(MaintenanceRecord)
    if equipment_type:
        query = query.filter(MaintenanceRecord.equipment_type == equipment_type)
    if truck_id:
        query = query.filter(MaintenanceRecord.truck_id == truck_id)
    if trailer_id:
        query = query.filter(MaintenanceRecord.trailer_id == trailer_id)
    records = query.order_by(MaintenanceRecord.date_completed.desc().nullslast()).all()
    return [_to_out(r) for r in records]


@router.post("", response_model=schemas.MaintenanceOut, status_code=201)
def create_record(
    payload: schemas.MaintenanceCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    _validate_link(payload)
    record = MaintenanceRecord(**payload.model_dump())
    db.add(record)
    db.flush()
    log_activity(db, entity_type="maintenance", entity_id=record.id, user=user, action="created")
    db.commit()
    db.refresh(record)
    return _to_out(record)


@router.get("/{record_id}", response_model=schemas.MaintenanceOut)
def get_record(record_id: int, db: Session = Depends(get_db)):
    return _to_out(get_or_404(db, MaintenanceRecord, record_id))


@router.patch("/{record_id}", response_model=schemas.MaintenanceOut)
def update_record(
    record_id: int,
    payload: schemas.MaintenanceUpdate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    record = get_or_404(db, MaintenanceRecord, record_id)
    apply_update(db, record, payload, entity_type="maintenance", user=user)
    return _to_out(record)

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app import schemas
from app.api.crud_helpers import apply_update, get_or_404
from app.core.deps import get_current_user, require_roles
from app.db import get_db
from app.models import Driver, DriverStatus, User, UserRole
from app.services.audit import log_activity

router = APIRouter(
    prefix="/api/drivers",
    tags=["drivers"],
    dependencies=[Depends(require_roles(UserRole.DISPATCHER, UserRole.ACCOUNTANT))],
)


@router.get("", response_model=list[schemas.DriverOut])
def list_drivers(q: str = "", status: DriverStatus | None = None, db: Session = Depends(get_db)):
    query = db.query(Driver)
    if status:
        query = query.filter(Driver.status == status)
    if q:
        query = query.filter(Driver.full_name.ilike(f"%{q}%"))
    return query.order_by(Driver.full_name).all()


@router.post("", response_model=schemas.DriverOut, status_code=201)
def create_driver(
    payload: schemas.DriverCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    driver = Driver(**payload.model_dump())
    db.add(driver)
    db.flush()
    log_activity(db, entity_type="driver", entity_id=driver.id, user=user, action="created")
    db.commit()
    db.refresh(driver)
    return driver


@router.get("/{driver_id}", response_model=schemas.DriverOut)
def get_driver(driver_id: int, db: Session = Depends(get_db)):
    return get_or_404(db, Driver, driver_id)


@router.patch("/{driver_id}", response_model=schemas.DriverOut)
def update_driver(
    driver_id: int,
    payload: schemas.DriverUpdate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    driver = get_or_404(db, Driver, driver_id)
    apply_update(db, driver, payload, entity_type="driver", user=user)
    return driver

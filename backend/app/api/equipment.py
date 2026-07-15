"""Trucks and trailers share identical CRUD; one factory builds both routers."""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app import schemas
from app.api.crud_helpers import apply_update, get_or_404
from app.core.deps import get_current_user, require_roles
from app.db import get_db
from app.models import EquipmentStatus, Trailer, Truck, User, UserRole
from app.services.audit import log_activity


def build_router(model, name: str) -> APIRouter:
    router = APIRouter(
        prefix=f"/api/{name}s",
        tags=[f"{name}s"],
        dependencies=[
            Depends(require_roles(UserRole.DISPATCHER, UserRole.ACCOUNTANT, UserRole.MAINTENANCE))
        ],
    )

    @router.get("", response_model=list[schemas.EquipmentOut])
    def list_items(q: str = "", status: EquipmentStatus | None = None, db: Session = Depends(get_db)):
        query = db.query(model)
        if status:
            query = query.filter(model.status == status)
        if q:
            query = query.filter(model.unit_number.ilike(f"%{q}%"))
        return query.order_by(model.unit_number).all()

    @router.post("", response_model=schemas.EquipmentOut, status_code=201)
    def create_item(
        payload: schemas.EquipmentCreate,
        db: Session = Depends(get_db),
        user: User = Depends(get_current_user),
    ):
        if db.query(model).filter(model.unit_number == payload.unit_number).first():
            raise HTTPException(status_code=409, detail="Unit number already exists")
        item = model(**payload.model_dump())
        db.add(item)
        db.flush()
        log_activity(db, entity_type=name, entity_id=item.id, user=user, action="created")
        db.commit()
        db.refresh(item)
        return item

    @router.get("/{item_id}", response_model=schemas.EquipmentOut)
    def get_item(item_id: int, db: Session = Depends(get_db)):
        return get_or_404(db, model, item_id)

    @router.patch("/{item_id}", response_model=schemas.EquipmentOut)
    def update_item(
        item_id: int,
        payload: schemas.EquipmentUpdate,
        db: Session = Depends(get_db),
        user: User = Depends(get_current_user),
    ):
        item = get_or_404(db, model, item_id)
        apply_update(db, item, payload, entity_type=name, user=user)
        return item

    return router


trucks_router = build_router(Truck, "truck")
trailers_router = build_router(Trailer, "trailer")

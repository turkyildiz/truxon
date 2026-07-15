from fastapi import APIRouter, Depends
from sqlalchemy import or_
from sqlalchemy.orm import Session

from app import schemas
from app.api.crud_helpers import apply_update, get_or_404
from app.core.deps import get_current_user, require_roles
from app.db import get_db
from app.models import Customer, User, UserRole
from app.services.audit import log_activity

router = APIRouter(
    prefix="/api/customers",
    tags=["customers"],
    dependencies=[Depends(require_roles(UserRole.DISPATCHER, UserRole.ACCOUNTANT))],
)


@router.get("", response_model=list[schemas.CustomerOut])
def list_customers(
    q: str = "",
    include_inactive: bool = False,
    db: Session = Depends(get_db),
):
    query = db.query(Customer)
    if not include_inactive:
        query = query.filter(Customer.is_active.is_(True))
    if q:
        like = f"%{q}%"
        query = query.filter(or_(Customer.company_name.ilike(like), Customer.contact_person.ilike(like)))
    return query.order_by(Customer.company_name).all()


@router.post("", response_model=schemas.CustomerOut, status_code=201)
def create_customer(
    payload: schemas.CustomerCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    customer = Customer(**payload.model_dump())
    db.add(customer)
    db.flush()
    log_activity(db, entity_type="customer", entity_id=customer.id, user=user, action="created")
    db.commit()
    db.refresh(customer)
    return customer


@router.get("/{customer_id}", response_model=schemas.CustomerOut)
def get_customer(customer_id: int, db: Session = Depends(get_db)):
    return get_or_404(db, Customer, customer_id)


@router.patch("/{customer_id}", response_model=schemas.CustomerOut)
def update_customer(
    customer_id: int,
    payload: schemas.CustomerUpdate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    customer = get_or_404(db, Customer, customer_id)
    apply_update(db, customer, payload, entity_type="customer", user=user)
    return customer

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response
from sqlalchemy.orm import Session

from app import schemas
from app.api.crud_helpers import get_or_404
from app.core.deps import get_current_user, require_roles
from app.db import get_db
from app.models import Customer, Invoice, InvoiceStatus, Load, LoadStatus, User, UserRole
from app.services.audit import log_activity
from app.services.invoice_pdf import build_invoice_pdf

router = APIRouter(
    prefix="/api/invoices",
    tags=["invoices"],
    dependencies=[Depends(require_roles(UserRole.ACCOUNTANT, UserRole.DISPATCHER))],
)


def next_invoice_number(db: Session) -> str:
    year = datetime.now(timezone.utc).year
    prefix = f"INV-{year}-"
    last = (
        db.query(Invoice.invoice_number)
        .filter(Invoice.invoice_number.like(f"{prefix}%"))
        .order_by(Invoice.invoice_number.desc())
        .first()
    )
    seq = int(last[0].removeprefix(prefix)) + 1 if last else 1
    return f"{prefix}{seq:04d}"


def to_out(inv: Invoice) -> schemas.InvoiceOut:
    out = schemas.InvoiceOut.model_validate(inv)
    out.customer_name = inv.customer.company_name if inv.customer else None
    out.load_count = len(inv.loads)
    return out


@router.get("", response_model=list[schemas.InvoiceOut])
def list_invoices(customer_id: int | None = None, db: Session = Depends(get_db)):
    query = db.query(Invoice)
    if customer_id:
        query = query.filter(Invoice.customer_id == customer_id)
    return [to_out(i) for i in query.order_by(Invoice.created_at.desc()).all()]


@router.post("", response_model=schemas.InvoiceOut, status_code=201)
def create_invoice(
    payload: schemas.InvoiceCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    get_or_404(db, Customer, payload.customer_id)
    loads = db.query(Load).filter(Load.id.in_(payload.load_ids)).all()
    if len(loads) != len(set(payload.load_ids)):
        raise HTTPException(status_code=404, detail="One or more loads not found")
    for load in loads:
        if load.customer_id != payload.customer_id:
            raise HTTPException(status_code=409, detail=f"{load.load_number} belongs to a different customer")
        if load.status != LoadStatus.COMPLETED:
            raise HTTPException(status_code=409, detail=f"{load.load_number} is not completed")
        if load.invoice_id:
            raise HTTPException(status_code=409, detail=f"{load.load_number} is already invoiced")

    invoice = Invoice(
        invoice_number=next_invoice_number(db),
        customer_id=payload.customer_id,
        due_date=payload.due_date,
        total=sum(l.rate for l in loads),
    )
    db.add(invoice)
    db.flush()
    for load in loads:
        load.invoice_id = invoice.id
        load.status = LoadStatus.BILLED
        log_activity(db, entity_type="load", entity_id=load.id, user=user,
                     action="status_changed", detail=f"completed → billed ({invoice.invoice_number})")
    db.commit()
    db.refresh(invoice)
    return to_out(invoice)


@router.get("/{invoice_id}", response_model=schemas.InvoiceOut)
def get_invoice(invoice_id: int, db: Session = Depends(get_db)):
    return to_out(get_or_404(db, Invoice, invoice_id))


@router.get("/{invoice_id}/pdf")
def invoice_pdf(invoice_id: int, db: Session = Depends(get_db)):
    invoice = get_or_404(db, Invoice, invoice_id)
    pdf = build_invoice_pdf(invoice)
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="{invoice.invoice_number}.pdf"'},
    )


@router.post("/{invoice_id}/status", response_model=schemas.InvoiceOut)
def set_invoice_status(
    invoice_id: int,
    status: InvoiceStatus,
    db: Session = Depends(get_db),
):
    invoice = get_or_404(db, Invoice, invoice_id)
    invoice.status = status
    db.commit()
    db.refresh(invoice)
    return to_out(invoice)


@router.delete("/{invoice_id}", status_code=204)
def void_invoice(invoice_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Void an invoice: loads revert to completed and become invoiceable again."""
    invoice = get_or_404(db, Invoice, invoice_id)
    for load in list(invoice.loads):
        load.invoice_id = None
        load.status = LoadStatus.COMPLETED
        log_activity(db, entity_type="load", entity_id=load.id, user=user,
                     action="status_changed", detail=f"billed → completed (invoice {invoice.invoice_number} voided)")
    db.delete(invoice)
    db.commit()

from datetime import datetime
from decimal import Decimal

from sqlalchemy import DateTime, Enum, ForeignKey, Numeric, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.enums import InvoiceStatus, LoadStatus


class Load(Base):
    __tablename__ = "loads"

    id: Mapped[int] = mapped_column(primary_key=True)
    load_number: Mapped[str] = mapped_column(String(30), unique=True, index=True)
    customer_id: Mapped[int] = mapped_column(ForeignKey("customers.id"), index=True)
    status: Mapped[LoadStatus] = mapped_column(
        Enum(LoadStatus, values_callable=lambda e: [m.value for m in e]),
        default=LoadStatus.PENDING,
        index=True,
    )

    pickup_address: Mapped[str] = mapped_column(Text, default="")
    pickup_time: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    delivery_address: Mapped[str] = mapped_column(Text, default="")
    delivery_time: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    driver_id: Mapped[int | None] = mapped_column(ForeignKey("drivers.id"))
    truck_id: Mapped[int | None] = mapped_column(ForeignKey("trucks.id"))
    trailer_id: Mapped[int | None] = mapped_column(ForeignKey("trailers.id"))

    rate: Mapped[Decimal] = mapped_column(Numeric(10, 2), default=Decimal("0"))
    miles: Mapped[Decimal] = mapped_column(Numeric(8, 1), default=Decimal("0"))
    special_terms: Mapped[str] = mapped_column(Text, default="")
    notes: Mapped[str] = mapped_column(Text, default="")

    invoice_id: Mapped[int | None] = mapped_column(ForeignKey("invoices.id"))

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    customer = relationship("Customer", lazy="joined")
    driver = relationship("Driver", lazy="joined")
    truck = relationship("Truck", lazy="joined")
    trailer = relationship("Trailer", lazy="joined")
    invoice = relationship("Invoice", back_populates="loads")

    @property
    def rate_per_mile(self) -> Decimal | None:
        if self.miles and self.miles > 0:
            return (Decimal(self.rate) / Decimal(self.miles)).quantize(Decimal("0.01"))
        return None


class Invoice(Base):
    __tablename__ = "invoices"

    id: Mapped[int] = mapped_column(primary_key=True)
    invoice_number: Mapped[str] = mapped_column(String(30), unique=True, index=True)
    customer_id: Mapped[int] = mapped_column(ForeignKey("customers.id"))
    invoice_date: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    due_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    total: Mapped[Decimal] = mapped_column(Numeric(12, 2), default=Decimal("0"))
    status: Mapped[InvoiceStatus] = mapped_column(
        Enum(InvoiceStatus, values_callable=lambda e: [m.value for m in e]),
        default=InvoiceStatus.DRAFT,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    customer = relationship("Customer", lazy="joined")
    loads = relationship("Load", back_populates="invoice")

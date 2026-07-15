from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import Date, DateTime, Enum, Integer, Numeric, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.enums import EquipmentStatus


class _EquipmentBase:
    """Columns shared by trucks and trailers."""

    id: Mapped[int] = mapped_column(primary_key=True)
    unit_number: Mapped[str] = mapped_column(String(30), unique=True, index=True)
    make: Mapped[str] = mapped_column(String(60), default="")
    model: Mapped[str] = mapped_column(String(60), default="")
    year: Mapped[int | None] = mapped_column(Integer)
    vin: Mapped[str] = mapped_column(String(30), default="")
    in_service_date: Mapped[date | None] = mapped_column(Date)
    out_of_service_date: Mapped[date | None] = mapped_column(Date)
    monthly_cost: Mapped[Decimal] = mapped_column(Numeric(10, 2), default=Decimal("0"))
    status: Mapped[EquipmentStatus] = mapped_column(
        Enum(EquipmentStatus, values_callable=lambda e: [m.value for m in e]),
        default=EquipmentStatus.AVAILABLE,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class Truck(_EquipmentBase, Base):
    __tablename__ = "trucks"


class Trailer(_EquipmentBase, Base):
    __tablename__ = "trailers"

from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import Date, DateTime, Enum, ForeignKey, Numeric, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.enums import EquipmentType


class MaintenanceRecord(Base):
    __tablename__ = "maintenance_records"

    id: Mapped[int] = mapped_column(primary_key=True)
    equipment_type: Mapped[EquipmentType] = mapped_column(
        Enum(EquipmentType, values_callable=lambda e: [m.value for m in e])
    )
    truck_id: Mapped[int | None] = mapped_column(ForeignKey("trucks.id"))
    trailer_id: Mapped[int | None] = mapped_column(ForeignKey("trailers.id"))
    date_completed: Mapped[date | None] = mapped_column(Date)
    description: Mapped[str] = mapped_column(Text, default="")
    cost: Mapped[Decimal] = mapped_column(Numeric(10, 2), default=Decimal("0"))
    technician_shop: Mapped[str] = mapped_column(String(200), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    truck = relationship("Truck", lazy="joined")
    trailer = relationship("Trailer", lazy="joined")

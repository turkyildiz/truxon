from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import Date, DateTime, Enum, Numeric, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.enums import DriverStatus


class Driver(Base):
    __tablename__ = "drivers"

    id: Mapped[int] = mapped_column(primary_key=True)
    full_name: Mapped[str] = mapped_column(String(120), index=True)
    license_number: Mapped[str] = mapped_column(String(40), default="")
    license_expiration: Mapped[date | None] = mapped_column(Date)
    date_of_birth: Mapped[date | None] = mapped_column(Date)
    hire_date: Mapped[date | None] = mapped_column(Date)
    # Dollars per mile, e.g. 0.450 = 45¢/mile
    pay_per_mile: Mapped[Decimal] = mapped_column(Numeric(6, 3), default=Decimal("0"))
    status: Mapped[DriverStatus] = mapped_column(
        Enum(DriverStatus, values_callable=lambda e: [m.value for m in e]), default=DriverStatus.ACTIVE
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

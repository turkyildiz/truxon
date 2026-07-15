from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base


class Document(Base):
    """An uploaded file (BOL, POD, license copy, receipt, …) linked to a record."""

    __tablename__ = "documents"

    id: Mapped[int] = mapped_column(primary_key=True)
    # e.g. "load", "driver", "truck", "trailer", "customer", "maintenance"
    entity_type: Mapped[str] = mapped_column(String(30), index=True)
    entity_id: Mapped[int] = mapped_column(Integer, index=True)
    doc_type: Mapped[str] = mapped_column(String(60), default="")  # BOL, POD, license, receipt…
    filename: Mapped[str] = mapped_column(String(255))
    stored_path: Mapped[str] = mapped_column(String(500))
    content_type: Mapped[str] = mapped_column(String(120), default="application/octet-stream")
    size_bytes: Mapped[int] = mapped_column(Integer, default=0)
    uploaded_by_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    uploaded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    uploaded_by = relationship("User", lazy="joined")


class ActivityLog(Base):
    """Timestamped audit trail: who changed what and when. action='note' entries
    are user-written notes; everything else is automatic."""

    __tablename__ = "activity_log"

    id: Mapped[int] = mapped_column(primary_key=True)
    entity_type: Mapped[str] = mapped_column(String(30), index=True)
    entity_id: Mapped[int] = mapped_column(Integer, index=True)
    user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    action: Mapped[str] = mapped_column(String(40))  # created | updated | status_changed | note | …
    detail: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    user = relationship("User", lazy="joined")

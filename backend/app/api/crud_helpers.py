"""Shared helpers used by the CRUD routers."""

from fastapi import HTTPException
from sqlalchemy.orm import Session

from app.models import User
from app.services.audit import log_activity


def get_or_404(db: Session, model, obj_id: int):
    obj = db.get(model, obj_id)
    if not obj:
        raise HTTPException(status_code=404, detail=f"{model.__name__} not found")
    return obj


def apply_update(db: Session, obj, payload, *, entity_type: str, user: User) -> None:
    """Apply a partial update and audit-log the changed fields."""
    data = payload.model_dump(exclude_unset=True)
    changed = []
    for key, value in data.items():
        if getattr(obj, key) != value:
            changed.append(key)
            setattr(obj, key, value)
    if changed:
        log_activity(
            db,
            entity_type=entity_type,
            entity_id=obj.id,
            user=user,
            action="updated",
            detail=f"Changed: {', '.join(changed)}",
        )
    db.commit()
    db.refresh(obj)

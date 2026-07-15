from sqlalchemy.orm import Session

from app.models import ActivityLog, User


def log_activity(
    db: Session,
    *,
    entity_type: str,
    entity_id: int,
    user: User | None,
    action: str,
    detail: str = "",
) -> None:
    """Append an audit entry. Caller is responsible for committing."""
    db.add(
        ActivityLog(
            entity_type=entity_type,
            entity_id=entity_id,
            user_id=user.id if user else None,
            action=action,
            detail=detail,
        )
    )

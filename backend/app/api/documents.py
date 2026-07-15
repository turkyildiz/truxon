"""Document upload/download plus notes & activity log, shared by all modules."""

import re
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from app import schemas
from app.core.config import get_settings
from app.core.deps import get_current_user
from app.db import get_db
from app.models import ActivityLog, Document, User
from app.services.audit import log_activity

router = APIRouter(prefix="/api", tags=["documents"])

VALID_ENTITIES = {"load", "driver", "truck", "trailer", "customer", "maintenance"}
MAX_UPLOAD_BYTES = 25 * 1024 * 1024


def _check_entity(entity_type: str) -> None:
    if entity_type not in VALID_ENTITIES:
        raise HTTPException(status_code=422, detail=f"entity_type must be one of {sorted(VALID_ENTITIES)}")


@router.get("/documents/{entity_type}/{entity_id}", response_model=list[schemas.DocumentOut])
def list_documents(
    entity_type: str,
    entity_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
):
    _check_entity(entity_type)
    return (
        db.query(Document)
        .filter(Document.entity_type == entity_type, Document.entity_id == entity_id)
        .order_by(Document.uploaded_at.desc())
        .all()
    )


@router.post("/documents/{entity_type}/{entity_id}", response_model=schemas.DocumentOut, status_code=201)
async def upload_document(
    entity_type: str,
    entity_id: int,
    file: UploadFile,
    doc_type: str = "",
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    _check_entity(entity_type)
    content = await file.read()
    if len(content) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="File too large (25 MB max)")

    settings = get_settings()
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", file.filename or "upload")
    subdir = settings.upload_dir / entity_type / str(entity_id)
    subdir.mkdir(parents=True, exist_ok=True)
    stored = subdir / f"{uuid.uuid4().hex[:12]}_{safe_name}"
    stored.write_bytes(content)

    doc = Document(
        entity_type=entity_type,
        entity_id=entity_id,
        doc_type=doc_type,
        filename=file.filename or "upload",
        stored_path=str(stored),
        content_type=file.content_type or "application/octet-stream",
        size_bytes=len(content),
        uploaded_by_id=user.id,
    )
    db.add(doc)
    log_activity(db, entity_type=entity_type, entity_id=entity_id, user=user,
                 action="document_uploaded", detail=file.filename or "upload")
    db.commit()
    db.refresh(doc)
    return doc


@router.get("/documents/file/{doc_id}")
def download_document(doc_id: int, db: Session = Depends(get_db), _: User = Depends(get_current_user)):
    doc = db.get(Document, doc_id)
    if not doc:
        raise HTTPException(status_code=404, detail="Document not found")
    path = Path(doc.stored_path)
    if not path.exists():
        raise HTTPException(status_code=410, detail="File missing from storage")
    return FileResponse(path, filename=doc.filename, media_type=doc.content_type)


@router.delete("/documents/file/{doc_id}", status_code=204)
def delete_document(doc_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    doc = db.get(Document, doc_id)
    if not doc:
        raise HTTPException(status_code=404, detail="Document not found")
    Path(doc.stored_path).unlink(missing_ok=True)
    log_activity(db, entity_type=doc.entity_type, entity_id=doc.entity_id, user=user,
                 action="document_deleted", detail=doc.filename)
    db.delete(doc)
    db.commit()


@router.get("/activity/{entity_type}/{entity_id}", response_model=list[schemas.ActivityOut])
def list_activity(
    entity_type: str,
    entity_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
):
    entries = (
        db.query(ActivityLog)
        .filter(ActivityLog.entity_type == entity_type, ActivityLog.entity_id == entity_id)
        .order_by(ActivityLog.created_at.desc())
        .limit(200)
        .all()
    )
    out = []
    for e in entries:
        item = schemas.ActivityOut.model_validate(e)
        item.user_name = e.user.full_name or e.user.username if e.user else None
        out.append(item)
    return out


@router.post("/activity/{entity_type}/{entity_id}/notes", response_model=schemas.ActivityOut, status_code=201)
def add_note(
    entity_type: str,
    entity_id: int,
    payload: schemas.NoteCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    entry = ActivityLog(
        entity_type=entity_type, entity_id=entity_id, user_id=user.id, action="note", detail=payload.detail
    )
    db.add(entry)
    db.commit()
    db.refresh(entry)
    out = schemas.ActivityOut.model_validate(entry)
    out.user_name = user.full_name or user.username
    return out

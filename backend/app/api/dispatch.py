"""Dispatch helpers: AI PDF extraction and distance calculation."""

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from pydantic import BaseModel

from app.core.deps import require_roles
from app.models import UserRole
from app.services.maps import calculate_miles
from app.services.pdf_extract import extract_load_fields

router = APIRouter(
    prefix="/api/dispatch",
    tags=["dispatch"],
    dependencies=[Depends(require_roles(UserRole.DISPATCHER))],
)


@router.post("/extract-pdf")
async def extract_pdf(file: UploadFile):
    if file.content_type not in ("application/pdf", "application/octet-stream"):
        raise HTTPException(status_code=422, detail="Upload a PDF file")
    content = await file.read()
    if len(content) > 15 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="PDF too large (15 MB max)")
    return await extract_load_fields(content)


class DistanceRequest(BaseModel):
    origin: str
    destination: str


@router.post("/distance")
async def distance(payload: DistanceRequest):
    miles = await calculate_miles(payload.origin, payload.destination)
    return {"miles": miles, "available": miles is not None}

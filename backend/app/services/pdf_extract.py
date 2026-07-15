"""AI-assisted extraction of load details from rate confirmation / load tender PDFs.

Pipeline: pdfplumber pulls the raw text, then a small LLM (OpenRouter/Groq
compatible endpoint) structures it into the fields we need. If no LLM key is
configured we still return the raw text so the dispatcher can copy/paste.
"""

import io
import json
import logging

import httpx
import pdfplumber

from app.core.config import get_settings

logger = logging.getLogger(__name__)

EXTRACTION_PROMPT = """You extract structured data from trucking rate confirmation documents.
Given the document text, respond with ONLY a JSON object (no markdown fences) with these keys:
- customer_name: the broker or customer company name issuing the load
- pickup_address: full pickup address
- pickup_time: pickup date/time in ISO 8601 format (null if not found)
- delivery_address: full delivery address
- delivery_time: delivery date/time in ISO 8601 format (null if not found)
- rate: total rate in dollars as a number (no currency symbol)
- special_terms: any special instructions or terms, as a short string
Use null for anything not present in the document.

Document text:
"""


def extract_text(pdf_bytes: bytes) -> str:
    with pdfplumber.open(io.BytesIO(pdf_bytes)) as pdf:
        return "\n".join(page.extract_text() or "" for page in pdf.pages)


async def extract_load_fields(pdf_bytes: bytes) -> dict:
    """Returns {"raw_text": str, "fields": dict | None, "error": str | None}."""
    try:
        text = extract_text(pdf_bytes)
    except Exception as exc:
        logger.exception("PDF text extraction failed")
        return {"raw_text": "", "fields": None, "error": f"Could not read PDF: {exc}"}

    if not text.strip():
        return {"raw_text": "", "fields": None, "error": "PDF contains no extractable text (scanned image?)"}

    settings = get_settings()
    if not settings.llm_api_key:
        return {"raw_text": text, "fields": None, "error": "No LLM API key configured — fill fields manually"}

    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(
                f"{settings.llm_base_url}/chat/completions",
                headers={"Authorization": f"Bearer {settings.llm_api_key}"},
                json={
                    "model": settings.llm_model,
                    "messages": [{"role": "user", "content": EXTRACTION_PROMPT + text[:12000]}],
                    "temperature": 0,
                },
            )
            resp.raise_for_status()
            content = resp.json()["choices"][0]["message"]["content"].strip()
        if content.startswith("```"):
            content = content.strip("`").removeprefix("json").strip()
        fields = json.loads(content)
        return {"raw_text": text, "fields": fields, "error": None}
    except Exception as exc:
        logger.exception("LLM extraction failed")
        return {"raw_text": text, "fields": None, "error": f"AI extraction failed: {exc}"}

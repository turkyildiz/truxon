"""Distance calculation via the Google Maps Directions API.

Returns None when no API key is configured or the lookup fails — the UI
falls back to manual mileage entry in that case.
"""

import logging

import httpx

from app.core.config import get_settings

logger = logging.getLogger(__name__)

DIRECTIONS_URL = "https://maps.googleapis.com/maps/api/directions/json"


async def calculate_miles(origin: str, destination: str) -> float | None:
    settings = get_settings()
    if not settings.google_maps_api_key or not origin or not destination:
        return None
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(
                DIRECTIONS_URL,
                params={
                    "origin": origin,
                    "destination": destination,
                    "key": settings.google_maps_api_key,
                },
            )
            data = resp.json()
        if data.get("status") != "OK":
            logger.warning("Directions API returned status %s", data.get("status"))
            return None
        meters = sum(leg["distance"]["value"] for leg in data["routes"][0]["legs"])
        return round(meters / 1609.344, 1)
    except Exception:
        logger.exception("Distance lookup failed")
        return None

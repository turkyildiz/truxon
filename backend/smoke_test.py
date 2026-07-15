"""End-to-end smoke test against a temporary SQLite database.

Run:  .venv/bin/python smoke_test.py
"""

import os
import tempfile

os.environ["TRUCKSON_DATABASE_URL"] = f"sqlite:///{tempfile.mkdtemp()}/smoke.db"
os.environ["TRUCKSON_UPLOAD_DIR"] = tempfile.mkdtemp()

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402

passed = 0


def check(label: str, condition: bool, extra: str = ""):
    global passed
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label} {extra}")
    if not condition:
        raise SystemExit(1)
    passed += 1


with TestClient(app) as client:
    # auth
    r = client.post("/api/auth/login", data={"username": "admin", "password": "admin"})
    check("admin login", r.status_code == 200)
    headers = {"Authorization": f"Bearer {r.json()['access_token']}"}

    r = client.get("/api/loads")
    check("unauthenticated request rejected", r.status_code == 401)

    # RBAC: maintenance user cannot see loads
    r = client.post("/api/users", headers=headers, json={
        "username": "mechanic", "password": "wrench123", "role": "maintenance", "full_name": "Mech"})
    check("create maintenance user", r.status_code == 201)
    r = client.post("/api/auth/login", data={"username": "mechanic", "password": "wrench123"})
    mech_headers = {"Authorization": f"Bearer {r.json()['access_token']}"}
    r = client.get("/api/loads", headers=mech_headers)
    check("RBAC blocks maintenance from loads", r.status_code == 403)
    r = client.get("/api/trucks", headers=mech_headers)
    check("RBAC allows maintenance to read trucks", r.status_code == 200)

    # core records
    r = client.post("/api/customers", headers=headers, json={"company_name": "Acme Freight", "payment_terms": "Net 15"})
    check("create customer", r.status_code == 201)
    customer_id = r.json()["id"]

    r = client.post("/api/drivers", headers=headers, json={"full_name": "John Yilmaz", "pay_per_mile": "0.55"})
    check("create driver", r.status_code == 201)
    driver_id = r.json()["id"]

    r = client.post("/api/trucks", headers=headers, json={"unit_number": "TRK-101", "make": "Freightliner", "year": 2022})
    check("create truck", r.status_code == 201)
    truck_id = r.json()["id"]

    r = client.post("/api/trailers", headers=headers, json={"unit_number": "TRL-205"})
    check("create trailer", r.status_code == 201)
    trailer_id = r.json()["id"]

    r = client.post("/api/maintenance", headers=headers, json={
        "equipment_type": "truck", "truck_id": truck_id, "description": "Oil change", "cost": "350.00"})
    check("create maintenance record", r.status_code == 201, f"unit={r.json()['equipment_unit']}")

    # load lifecycle
    r = client.post("/api/loads", headers=headers, json={
        "customer_id": customer_id,
        "pickup_address": "Chicago, IL", "pickup_time": "2026-07-13T08:00:00Z",
        "delivery_address": "Dallas, TX", "delivery_time": "2026-07-14T17:00:00Z",
        "driver_id": driver_id, "truck_id": truck_id, "trailer_id": trailer_id,
        "rate": "2450.00", "miles": "925.0"})
    check("create load (auto-assigned)", r.status_code == 201 and r.json()["status"] == "assigned")
    load = r.json()
    check("load number generated", load["load_number"].startswith("LD-2026-"), load["load_number"])
    check("rate per mile computed", load["rate_per_mile"] == "2.65", f"= {load['rate_per_mile']}")

    r = client.get(f"/api/trucks/{truck_id}", headers=headers)
    check("truck marked in_use", r.json()["status"] == "in_use")

    load_id = load["id"]
    r = client.post(f"/api/loads/{load_id}/status", headers=headers, json={"status": "delivered"})
    check("skipping a status is rejected", r.status_code == 409)
    for status in ("in_transit", "delivered", "completed"):
        r = client.post(f"/api/loads/{load_id}/status", headers=headers, json={"status": status})
        check(f"advance to {status}", r.status_code == 200)
    r = client.get(f"/api/trucks/{truck_id}", headers=headers)
    check("truck available after delivery", r.json()["status"] == "available")

    r = client.post(f"/api/loads/{load_id}/status", headers=headers, json={"status": "billed"})
    check("billed without invoice rejected", r.status_code == 409)

    # invoicing
    r = client.post("/api/invoices", headers=headers, json={"customer_id": customer_id, "load_ids": [load_id]})
    check("create invoice", r.status_code == 201, r.json().get("invoice_number", ""))
    invoice_id = r.json()["id"]
    check("invoice total", r.json()["total"] == "2450.00")
    r = client.get(f"/api/loads/{load_id}", headers=headers)
    check("load now billed", r.json()["status"] == "billed")
    r = client.get(f"/api/invoices/{invoice_id}/pdf", headers=headers)
    check("invoice PDF renders", r.status_code == 200 and r.content[:4] == b"%PDF", f"{len(r.content)} bytes")

    # notes + activity
    r = client.post(f"/api/activity/load/{load_id}/notes", headers=headers, json={"detail": "POD received"})
    check("add note", r.status_code == 201)
    r = client.get(f"/api/activity/load/{load_id}", headers=headers)
    actions = [e["action"] for e in r.json()]
    check("audit trail recorded", "created" in actions and "status_changed" in actions and "note" in actions,
          f"{len(actions)} entries")

    # reports + dashboard + search
    r = client.get("/api/reports/weekly", headers=headers, params={"week_of": "2026-07-14"})
    check("weekly report", r.status_code == 200)
    rep = r.json()
    check("driver pay computed", rep["by_driver"][0]["driver_pay"] == "508.75", f"= {rep['by_driver'][0]['driver_pay']}")
    check("weekly totals", rep["totals"]["loads"] == 1 and rep["totals"]["revenue"] == "2450.00")

    r = client.get("/api/dashboard", headers=headers)
    check("dashboard", r.status_code == 200, f"trucks avail={r.json()['available_trucks']}")

    r = client.get("/api/search", headers=headers, params={"q": "acme"})
    check("global search", r.status_code == 200 and len(r.json()["customers"]) == 1)

    # dispatch distance endpoint degrades gracefully without API key
    r = client.post("/api/dispatch/distance", headers=headers,
                    json={"origin": "Chicago, IL", "destination": "Dallas, TX"})
    check("distance endpoint (no key => unavailable)", r.status_code == 200 and r.json()["available"] is False)

print(f"\nAll {passed} checks passed.")

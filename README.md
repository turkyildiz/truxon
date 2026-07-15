# TrucksOn TMS

Web-based Transportation Management System for small-to-mid-sized trucking companies.
Spec: [docs/TrucksOn_TMS_Requirements_MVP_v1.0.pdf](docs/TrucksOn_TMS_Requirements_MVP_v1.0.pdf)

**Stack:** FastAPI + SQLAlchemy + PostgreSQL · React + TypeScript + Tailwind · Docker

## Modules

Customers · Drivers · Trucks · Trailers · Maintenance · **Loads** (6-status workflow:
pending → assigned → in transit → delivered → completed → billed) · Dispatch (manual +
AI PDF extraction) · Weekly accounting (Mon–Sun, per truck/driver with driver pay) ·
Invoicing (PDF export) · Dashboard · Global search · Documents & audit log on every record ·
RBAC (admin / dispatcher / driver / accountant / maintenance).

## Local development

```bash
# Backend (SQLite fallback — no Postgres needed for dev)
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app.main:app --reload --port 8000
# First run creates an admin/admin account — change it immediately.

# Frontend (separate terminal; proxies /api to :8000)
cd frontend
npm install
npm run dev            # http://localhost:5173

# Backend API test suite
cd backend && .venv/bin/python smoke_test.py
```

API docs (Swagger): http://localhost:8000/docs

## Production deployment (UGREEN NAS / any Docker host)

```bash
cp .env.example .env       # fill in DB_PASSWORD, SECRET_KEY (openssl rand -hex 32), etc.
docker compose up -d --build
# App: http://<nas-ip>:8080  — log in with INITIAL_ADMIN_PASSWORD from .env
```

Optional integrations (set in `.env`, features degrade gracefully without them):

| Variable | Enables |
|---|---|
| `GOOGLE_MAPS_API_KEY` | Automatic mileage calculation |
| `LLM_API_KEY` (OpenRouter/Groq) | AI extraction from rate-confirmation PDFs |

### Security checklist (per spec §16)

- Do **not** port-forward the NAS to the internet; use VPN (WireGuard/Tailscale) for remote access.
- Change the initial admin password on first login; create per-person accounts with least-privilege roles.
- Keep the Docker host and images updated (`docker compose pull && docker compose up -d`).

### Backups (3-2-1-1-0)

```bash
# Nightly cron on the NAS:
BACKUP_PASSPHRASE=... deploy/backup/backup.sh /volume1/backups/truckson
# Weekly restore verification:
BACKUP_PASSPHRASE=... deploy/backup/restore_test.sh /volume1/backups/truckson
```

Point the NAS's **immutable snapshot** feature at the backup folder (30-day retention)
for the ransomware-proof copy, and sync it to encrypted cloud storage for offsite.

## Repository layout

```
backend/    FastAPI app: app/{models,schemas.py,api,services,core}, alembic migrations
frontend/   React app: src/{pages,components,api.ts,auth.tsx}
deploy/     backup + restore-test scripts
docs/       requirements spec
```

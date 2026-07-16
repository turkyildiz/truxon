# Truxon TMS — Technical Reference

Architecture, data model, and operations for developers. See also the
top-level [README](../README.md), [User Guide](USER_GUIDE.md), and
[Admin Guide](ADMIN_GUIDE.md).

---

## 1. Architecture

**Supabase-native.** The React SPA talks directly to Supabase; there is no
application server to run.

```
Browser (React SPA on Vercel, truxon.com)
        │  supabase-js  (anon key, RLS-enforced)
        ▼
Supabase ── Postgres 17 (tables, SECURITY DEFINER RPCs, RLS)
        ├── Auth (email/password, sign-up disabled)
        ├── Storage (documents, personal, team buckets)
        └── Edge Functions (Deno): extract-pdf, distance, admin-users
        │
UGREEN NAS ── nightly encrypted pull (pg_dump + storage tar) + immutable snapshots
QuickBooks Online ── accounting system of record (Aida Logistics LLC)
```

- **Frontend:** React + TypeScript + Vite + Tailwind v4 + react-router +
  @tanstack/react-query + supabase-js + jsPDF + recharts + pdfjs-dist.
- **Hosting:** Vercel (auto-deploy from GitHub `main`, SPA rewrites in
  `frontend/vercel.json`), custom domain `truxon.com` (GoDaddy DNS).
- **Repo:** `turkyildiz/truxon` (private); GitHub Actions CI builds the
  frontend on every push/PR.
- **Supabase project:** ref `okoeeyxxvzypjiumraxq` (us-east-2).

## 2. Repo layout

```
frontend/            React app
  src/pages/         one file per screen (Dashboard, Dispatch, Loads, Drive…)
  src/components/    ResourcePage (generic list+modal), DocsNotes, StopsEditor,
                     PdfDrop, Layout, ui primitives
  src/data.ts        the ONLY place with query/RPC/storage/function calls
  src/auth.tsx       auth context + ROLE_MODULES matrix
  scripts/           qa_features.mjs, qa_extract.mjs (live QA harnesses)
supabase/
  migrations/        schema, RPCs, RLS, storage, incremental changes
  functions/         extract-pdf, distance, admin-users (+ _shared/auth.ts)
deploy/
  backup/            NAS backup.sh, storage_backup.py, restore_test.sh
  migration-its/     ITS Dispatch import + document/stop/field backfill tooling
docs/                these documents + the requirements spec + punch list
```

## 3. Data model (public schema)

| Table | Purpose |
|-------|---------|
| `profiles` | one row per auth user; `role` drives RBAC. |
| `customers` | brokers/shippers; contacts, billing, terms. |
| `drivers` | contact, license, pay-per-mile, `empty_miles_paid` + empty rate. |
| `trucks`, `trailers` | equipment; unit #, plate, status. |
| `maintenance_records` | repairs per truck/trailer. |
| `loads` | core; 6-status workflow, broker refs, equipment, rate, miles, empty miles. Primary route fields (pickup/delivery) are denormalized from the stops. |
| `load_stops` | ordered pickup/delivery itinerary (multi-stop). |
| `invoices` | Truxon-side invoice records + status. |
| `documents` | file metadata for any entity (`entity_type`/`entity_id`) → `documents` bucket. |
| `drive_files` | Personal/Team Drive metadata → `personal`/`team` buckets. |
| `activity_log` | notes + auto-logged status changes on any entity. |
| `company_settings` | single-row invoice branding. |
| `rate_limit_events` | per-user action counters (edge-function rate limiting). |

Enums: `load_status` (pending→assigned→in_transit→delivered→completed→billed),
`invoice_status` (draft/sent/paid). `my_role()` returns the caller's role.

## 4. Business logic in the database (SECURITY DEFINER RPCs)

`supabase/migrations/*_rpcs.sql` + later overrides:

- `change_load_status` — one-step transitions, guards (driver+truck before
  assigned; invoice before billed; **billed loads immutable**).
- `create_invoice` / `void_invoice` / `set_invoice_status` — invoicing; void
  reverts loads to completed atomically.
- `weekly_report` — Mon–Sun settlement; driver pay = miles×rate +
  (empty_miles×empty_rate if `empty_miles_paid`).
- `dashboard_summary`, `global_search` — role-gated (admin/dispatcher/
  accountant only).
- `check_rate_limit` — atomic per-user/action window counter.
- `next_load_number` / `next_invoice_number` — sequence-backed.

## 5. Row-level security

Every table has RLS on. Highlights:

- Operational tables: read for admin/dispatcher/accountant (+ maintenance on
  equipment/repairs); writes per the role matrix.
- **Invoices** write only through the RPCs.
- **documents / activity_log**: office roles everything; maintenance only
  truck/trailer/maintenance entities; drivers none.
- **drive_files & storage**: personal = owner only; team = all-staff read,
  own-file (or admin) delete. Enforced at both the table and
  `storage.objects` layer (path convention `<owner_uid>/…`).

Migrations `20260716150001_rbac_hardening.sql` and `20260716230001_drives.sql`
are the authoritative RBAC sources.

## 6. Edge functions (Deno)

- **extract-pdf** — auth+role gated, rate-limited, 15 MB cap. `unpdf` pulls
  text; an OpenRouter/Groq LLM structures it (`LLM_MODEL`). Scanned PDFs with
  no text layer trigger a vision path: the browser renders pages to JPEGs
  (`pdfjs-dist`) and a vision model reads them (`LLM_VISION_MODEL`). Returns
  load fields incl. every stop, or a customer profile in `mode=customer`.
- **distance** — Google Directions; sums legs through `waypoints` for
  multi-stop loads. Returns `{available:false}` with no key.
- **admin-users** — service-role user management (create/list/patch, ban on
  deactivate). The service_role key never leaves this function.

Secrets (Supabase → Edge Functions): `LLM_API_KEY`, optional `LLM_BASE_URL` /
`LLM_MODEL` / `LLM_VISION_MODEL`, `GOOGLE_MAPS_API_KEY`, `EXTRACT_RATE_MAX`.

## 7. Local dev & deploy

```bash
cd frontend
cp .env.example .env.local        # VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY
npm install && npm run dev        # http://localhost:5173
npx tsc -b && npm run build       # typecheck + prod build (CI runs both)
```

Schema change: add a file under `supabase/migrations/` (never edit an applied
one), then `supabase db push`. Deploy a function:
`supabase functions deploy <name>`. Frontend deploys on push to `main`.

Environment note (this workstation): Node at `~/.local/node/bin`, `gh` and
`supabase` CLIs at `~/.local/bin`. No system Node/Docker.

## 8. Backups & restore

`deploy/backup/backup.sh` (runs on the NAS): `pg_dump` (postgres:17 to match
the server) piped through `gpg AES256`, plus `storage_backup.py` tarring all
buckets, encrypted. `restore_test.sh` verifies the newest dump into a scratch
Postgres. `set -o pipefail` guards against silent empty dumps. 30-day
retention; UGOS immutable snapshots on top. Keep the gpg passphrase in a
password manager.

## 9. Single-tenant note

Truxon serves one carrier (Aida). Multi-tenant (`company_id` + tenant-scoped
RLS) is deliberate future scope, to be built when a second company onboards —
not a gap.

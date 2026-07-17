# Truxon TMS

Web-based Transportation Management System for small-to-mid-sized trucking companies.
Spec: [docs/Truxon_TMS_Requirements_MVP_v1.0.pdf](docs/Truxon_TMS_Requirements_MVP_v1.0.pdf)

**Architecture: Supabase-native.** The React app talks directly to Supabase —
Postgres (with the business rules in SQL functions/triggers + RLS), Auth,
Storage for documents, and edge functions for the AI/maps/admin work. There is
no application server to host. The UGREEN NAS's only job is pulling encrypted
backups.

```
frontend/            React + TypeScript + Tailwind (tablet-first UI)
mobile/              Flutter companion (driver GPS, loads, paperwork)
supabase/migrations/ Schema, workflow RPCs, RLS policies, storage bucket
supabase/functions/  extract-pdf (AI), distance (Google Maps), admin-users
deploy/backup/       NAS backup + restore-test scripts
docs/                Requirements spec
```

## Modules

Customers · Drivers · Trucks · Trailers · Maintenance · **Loads** (6-status
workflow enforced in Postgres: pending → assigned → in transit → delivered →
completed → billed) · Dispatch (manual + AI PDF extraction) · Weekly accounting
(Mon–Sun, per truck/driver with driver pay) · Invoicing (client-side PDF) ·
Dashboard · Global search · Documents & audit log on every record · RBAC via
RLS (admin / dispatcher / driver / accountant / maintenance).
**Companion app:** see [mobile/README.md](mobile/README.md) and design doc
[docs/design-trux-companion-app.md](docs/design-trux-companion-app.md) if present.

## One-time Supabase setup

1. Create a project at [supabase.com](https://supabase.com) (free tier is fine to start).
2. Link and push the database schema and edge functions:

   ```bash
   supabase login                      # or: export SUPABASE_ACCESS_TOKEN=...
   supabase link --project-ref <YOUR_PROJECT_REF>
   supabase db push                    # applies supabase/migrations/*
   supabase functions deploy extract-pdf distance admin-users notify trux-agent
   supabase secrets set LLM_API_KEY=... XAI_API_KEY=... GOOGLE_MAPS_API_KEY=...   # optional
   # One-shot when tokens are ready:  ./scripts/go-live.sh ~/truckson-live.env
   # Checklist: docs/GO_LIVE.md
   # Optional extraction overrides (defaults: OpenRouter + llama-3.1-8b):
   #   supabase secrets set LLM_BASE_URL=https://api.groq.com/openai/v1 LLM_MODEL=llama-3.3-70b-versatile
   ```

3. Create the first admin: Dashboard → Authentication → Add user
   (email + password, check "auto-confirm"), then in the SQL editor:

   ```sql
   update public.profiles set role = 'admin' where username = '<their username>';
   ```

   Every further user is created from the app's **Users** page.

4. Configure the frontend:

   ```bash
   cd frontend
   cp .env.example .env.local          # fill in Project URL + anon key
   npm install && npm run dev          # http://localhost:5173
   ```

## Deploying the frontend (Vercel)

One-time setup at [vercel.com](https://vercel.com):

1. **Add New → Project** → import the `turkyildiz/truxon` GitHub repo.
2. Set **Root Directory** to `frontend` (framework auto-detects as Vite;
   `frontend/vercel.json` already handles the SPA routing rewrites).
3. Add environment variables `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`
   (same values as `.env.local`).
4. Deploy. Every push to `main` now auto-deploys; PRs get preview URLs.

Then add the Vercel URL to Supabase → Authentication → URL Configuration
(Site URL + redirect URLs).

## Backups (3-2-1-1-0, pulled to the UGREEN NAS)

Live setup: a Docker Compose project `truxon-backup` runs on the NAS (UGOS
Docker app, at `docker/truxon-backup/`). It pulls from Supabase every night at
02:00 — an encrypted `pg_dump` of the database plus an encrypted tar of the
documents bucket — into `docker/truxon-backup/backups/`, with 30-day retention.
The container's compose embeds the backup scripts; the standalone copies in
[`deploy/backup/`](deploy/backup/) are the same logic kept for reference/portability.

Protection layers:
- **Cloud** — Supabase keeps its own daily server-side backups.
- **On-prem** — the nightly encrypted dumps on the NAS (gpg AES256; keep the
  passphrase in a password manager — without it the backups can't be restored).
- **Immutable** — UGOS Snapshot is enabled on the `docker` shared folder (daily,
  30-day retention): the copy ransomware can't alter.
- **Verified** — decrypt + restore the newest dump into a throwaway Postgres and
  check row counts (the "0 errors" step); the reference script is
  [`deploy/backup/restore_test.sh`](deploy/backup/restore_test.sh).

## Security notes

- Public sign-up is disabled; only admins create accounts (service-role key
  never leaves the `admin-users` edge function).
- Every table has row-level security; the load workflow and invoicing rules
  are enforced by SECURITY DEFINER functions, not client code.
- Reporting RPCs (`dashboard_summary`, `global_search`, `weekly_report`) and
  document/notes access are role-gated: driver and maintenance logins never
  see company-wide financials, the customer list, or other records' files.
- Billed loads are immutable — corrections go through **Void** on the
  invoice, which reverts its loads to `completed` in one transaction.
- Deactivating a user bans the auth account and revokes sessions.
- The AI PDF-extraction edge function is auth- and role-gated, size-capped
  (15 MB), and rate-limited to 30 extractions/user/hour (`check_rate_limit`).
- Single-tenant by design (one carrier). Multi-company/multi-tenant is a
  deliberate future scope item — it would add `company_id` + tenant-scoped RLS
  across all tables, not a change to make until a second company onboards.

## Development

```bash
cd frontend && npm run dev     # UI against your Supabase project
npx tsc -b && npm run build    # typecheck + production build (CI runs both)
```

Schema changes: add a new file under `supabase/migrations/` (never edit an
applied one) and run `supabase db push`.

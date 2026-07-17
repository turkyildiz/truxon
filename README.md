# Truxon TMS

Web-based Transportation Management System for small-to-mid-sized trucking companies.
Spec: [docs/TrucksOn_TMS_Requirements_MVP_v1.0.pdf](docs/TrucksOn_TMS_Requirements_MVP_v1.0.pdf)

**Architecture: Supabase-native.** The React app talks directly to Supabase —
Postgres (with the business rules in SQL functions/triggers + RLS), Auth,
Storage for documents, and edge functions for the AI/maps/admin work. There is
no application server to host. The UGREEN NAS's only job is pulling encrypted
backups.

```
frontend/            React + TypeScript + Tailwind (tablet-first UI)
supabase/migrations/ Schema, workflow RPCs, RLS policies, storage bucket
supabase/functions/  extract-pdf (AI), distance (Google Maps), admin-users
supabase/tests/      SQL workflow / RLS regression seeds
scripts/             Test harness (static security + smoke)
deploy/backup/       NAS backup + restore-test scripts
backend/             LEGACY — original FastAPI implementation, kept for reference
docs/                Requirements spec + TESTING.md
```

## Modules

Customers · Drivers · Trucks · Trailers · Maintenance · **Loads** (6-status
workflow enforced in Postgres: pending → assigned → in transit → delivered →
completed → billed) · Dispatch (manual + AI PDF extraction) · Weekly accounting
(Mon–Sun, per truck/driver with driver pay) · Invoicing (client-side PDF) ·
Dashboard · Global search · Documents & audit log on every record · RBAC via
RLS (admin / dispatcher / driver / accountant / maintenance).

## One-time Supabase setup

1. Create a project at [supabase.com](https://supabase.com) (free tier is fine to start).
2. Link and push the database schema and edge functions:

   ```bash
   supabase login                      # or: export SUPABASE_ACCESS_TOKEN=...
   supabase link --project-ref <YOUR_PROJECT_REF>
   supabase db push                    # applies supabase/migrations/*
   supabase functions deploy extract-pdf distance admin-users
   supabase secrets set LLM_API_KEY=... GOOGLE_MAPS_API_KEY=...   # optional
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

```bash
# Nightly cron on the NAS (put secrets in /etc/truckson-backup.env, chmod 600):
. /etc/truckson-backup.env && deploy/backup/backup.sh /volume1/backups/truckson
# Weekly restore verification:
. /etc/truckson-backup.env && deploy/backup/restore_test.sh /volume1/backups/truckson
```

- Encrypted `pg_dump` of the database + tar of the documents bucket, 30-day retention.
- Point the NAS's **immutable snapshot** feature at the backup folder — that's
  the copy ransomware can't touch.
- Supabase Pro additionally keeps its own daily backups server-side.

## Security notes

- Public sign-up is disabled; only admins create accounts (service-role key
  never leaves the `admin-users` edge function).
- Every table has row-level security; the load workflow and invoicing rules
  are enforced by SECURITY DEFINER functions, not client code.
- Deactivating a user bans the auth account and revokes sessions.

## Development

```bash
cd frontend && npm run dev     # UI against your Supabase project
npx tsc -b && npm run build    # typecheck + production build (CI runs both)
```

Schema changes: add a new file under `supabase/migrations/` (never edit an
applied one) and run `supabase db push`.

## Testing

```bash
./scripts/run-truxon-tests.sh                 # smoke (build) + static security
./scripts/run-truxon-tests.sh static-security # authz / workflow source checks only
./scripts/run-truxon-tests.sh sql             # needs DATABASE_URL or local Supabase
```

Full checklist, known baseline FAILs, and live E2E scripts: [docs/TESTING.md](docs/TESTING.md).
CI runs frontend build, static security (hard gate after Phase 0), and legacy backend smoke.

# Go-live checklist (companion + Trux agent)

## Trux email door (trux@truxon.com) — owner setup

Code is deployed (`trux-inbox` polls every 2 min via pg_cron and no-ops until
configured). To activate:

1. **M365 admin center → Teams & groups → Shared mailboxes → Add**:
   `trux@truxon.com` (free, no license). truxon.com must be a verified domain
   with MX in M365 (GoDaddy DNS change if mail isn't there yet).
2. **Azure portal → App registrations → New** ("Trux", single tenant).
3. App → **API permissions → Microsoft Graph → Application permissions** →
   add `Mail.ReadWrite` + `Mail.Send` → **Grant admin consent**.
4. **Certificates & secrets → New client secret**.
5. Supabase → Edge Functions → Secrets: set `MSGRAPH_TENANT_ID`,
   `MSGRAPH_CLIENT_ID`, `MSGRAPH_CLIENT_SECRET`.
   (Optional `TRUX_MAILBOX` if not trux@truxon.com.)
6. **Recommended** — scope the app to only the Trux mailbox (Exchange Online
   PowerShell):
   ```powershell
   New-ApplicationAccessPolicy -AppId <CLIENT_ID> -PolicyScopeGroupId trux@truxon.com \
     -AccessRight RestrictAccess -Description "Trux mailbox only"
   ```

Behavior: only mail from active admin/dispatcher/accountant accounts (matched
to Truxon logins, Exchange SPF/DKIM verdict honored) is acted on; actions run
AS the sender (RLS + audit); PDF attachments are parsed as data only; Trux
replies with what it did, including load numbers. Log: `trux_inbox_log`
(admin-visible).

**Code status:** companion Phase 1 is on `main` (PR #3). Agent + deploy tooling land in the follow-up PR.

## What auto-deploys

| Piece | How |
|-------|-----|
| **Web frontend** | Vercel on push to `main` |
| **Postgres / edge** | Manual — `scripts/go-live.sh` |

## One command (when you have tokens)

Create `~/truckson-live.env` (chmod 600):

```bash
export SUPABASE_ACCESS_TOKEN=sbp_...          # Account → Access Tokens
export SUPABASE_PROJECT_REF=okoeeyxxvzypjiumraxq  # production Truxon project
export XAI_API_KEY=xai-...                    # preferred LLM (Trux)
# or: export OPENAI_API_KEY=... / ANTHROPIC_API_KEY=...
export GOOGLE_MAPS_API_KEY=...                # distance edge function
export FCM_SERVICE_ACCOUNT_JSON='{"type":"service_account",...}'  # optional push
export NOTIFY_WEBHOOK_SECRET=$(openssl rand -hex 24)
```

```bash
cd ~/development/truxon   # or your clone
git pull origin main
./scripts/go-live.sh ~/truckson-live.env
```

## Vercel env (if not already set)

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`
- Optional: `VITE_GOOGLE_MAPS_JS_KEY` (browser Maps key, HTTP referrer restricted to your domain + localhost)

Redeploy after changing env vars.

## Day-of smoke (15 min)

1. Open production web URL — admin login works.
2. **Users** → create `role=driver` or **Drivers** → **Linked login**.
3. `cd mobile && flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`
4. Driver: **On duty** → pin appears on **Dispatch → Live fleet** within ~60s.
5. Driver: open load → status **In transit** → **Delivered**.
6. Dispatcher: **Trux assistant** — “list available trucks” (needs LLM secret).
7. Upload load document → linked driver can open **Paperwork** (push if FCM configured).

## Blocked without credentials on this machine

This Mac clone has **no** `.env.local` / Supabase access token. Frontend merged to `main` for Vercel; **DB push + function deploy must run where secrets live** (your Linux/NAS path historically was `/home/turkyildiz/TRUXON/frontend/.env.local`).

## Rollback

- Functions: redeploy previous git SHA of function folders.
- DB: do not edit applied migrations; add a fix migration.
- Frontend: Vercel → promote previous deployment.


## Known production project

- URL: `https://okoeeyxxvzypjiumraxq.supabase.co`
- Anon key lives in your machine’s `frontend/.env.local` (gitignored); restored from prior stress harness on this Mac if present.
- Still need **SUPABASE_ACCESS_TOKEN** (Dashboard → Account → Access Tokens) to run `go-live.sh`.

## Work machine (recommended tomorrow)

This Mac does **not** have your Supabase CLI login. The Linux/work box historically had:

- `/home/turkyildiz/TRUXON/frontend/.env.local`
- Possibly an existing `supabase login` session

**On the work machine:**

```bash
cd /path/to/truxon   # e.g. ~/TRUXON or git clone
git pull origin main
# if CLI not logged in yet:
supabase login      # opens browser once; creates sbp session on that machine

./scripts/go-live-from-work-machine.sh
# optional smoke (admin email/password):
node scripts/post-deploy-smoke.mjs you@email.com 'password'
```

`go-live-from-work-machine.sh` auto-loads `.env.local` from common paths and defaults project ref to `okoeeyxxvzypjiumraxq`.


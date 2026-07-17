# Go-live checklist (companion + Trux agent)

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
export SUPABASE_PROJECT_REF=abcdefghijklmn    # Project Settings → General
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

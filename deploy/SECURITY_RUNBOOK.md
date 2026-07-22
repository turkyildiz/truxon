# Truxon Security Runbook

Fast, tested actions for a suspected compromise. Everything here is reversible.
The DB URL / service key live only in the NAS `backup.env` — pull them into a
shell variable, never print them.

## 0. Signals that bring you here
- A **critical Forest finding**: `🍯 Honeypot accessed`, `🍯 Decoy credential
  replayed`, `🛡️ Admin access granted`, `🕵️ Canary login touched`, or
  `🔓 posture drift`.
- A push you didn't expect about admin access or a decoy.

## 1. Freeze the escalation path (break-glass, ~5 seconds)
Blocks all role changes / new accounts / admin grants. Crons and backups keep
running so you can recover.
```sql
select public.set_lockdown(true, 'reason here');   -- as an admin, or via psql
-- lift when clear:
select public.set_lockdown(false, 'all clear');
```

## 2. Full read-only freeze (superuser, whole database)
Stops every write from the API roles at once. Use if you think data is being
changed. `$DSN` = `SUPABASE_DB_URL` from NAS `backup.env`.
```bash
psql "$DSN" -c "alter role authenticator set default_transaction_read_only = on;"
# recover:
psql "$DSN" -c "alter role authenticator set default_transaction_read_only = off;"
```
(New connections pick it up; existing PostgREST pool recycles within seconds.)

## 3. Prove the audit log wasn't tampered with
```sql
select public.security_audit_verify();      -- {"intact": true, ...} or the broken id
select public.security_audit_recent(200);   -- what happened, newest first
```
If `intact:false`, a superuser-level actor edited history — treat the whole
platform account as compromised (rotate Supabase login + DB password).

## 4. Rotate credentials (one command each)
```bash
# CRON_SECRET (edge): generate, set, then seed the DB copy via the watchdog setter
NEW=$(openssl rand -hex 32)
supabase secrets set CRON_SECRET="$NEW"
curl -s "$SUPABASE_URL/functions/v1/watchdog" -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ADMIN_JWT" -d "{\"set_cron_secret\":\"$NEW\"}"
# hp_dsn (honeypot capture DSN) — re-set if the DB password changed:
psql "$DSN" -c "select public.set_cron_config('hp_dsn', '$DSN');"
```
Then rotate any third-party keys named in the finding (QBO, Denim, PrePass).
Supabase anon/service keys rotate from the dashboard → API settings.

## 5. Force every office user to re-authenticate
```bash
# revoke all refresh tokens (GoTrue admin) — everyone must log in again
psql "$DSN" -c "delete from auth.refresh_tokens;"   # sessions die on next refresh
```
Reset the specific account's password from the dashboard → Authentication.

## 6. After the incident
- Re-run `security_audit_verify()` and save `security_audit_recent()` output.
- If the drift finding was legitimate, `select public.bless_security_baseline();`
  (audited) to clear it.
- Write what happened into the security-posture memory.

## Honeypots & canaries — do not trip them yourself
- Never `select` from `public.api_keys` / `public.bank_accounts` (decoys).
- Never sign in as `ap-archive@aidalogistics.com` (canary — permanently inactive).
- Both page you. That's the point.

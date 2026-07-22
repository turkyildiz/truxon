---
title: Reference Index
tags: [moc, reference]
---

# 📚 Reference — pointers into the code repo

These living docs are maintained **in the repo** (`~/src/truxon/docs/`), not duplicated here (that would drift). This note is the map. Open them from the repo or your editor.

## Operations & runbooks
- `docs/OPERATIONS.md` — living ops reference: cron inventory, secret rotation, exam harness, APK-pending notes
- `deploy/SECURITY_RUNBOOK.md` — incident response, lockdown, break-glass
- `docs/THREAT_JADEPUFFER.md` — ransomware threat model + owner action items
- `docs/RESTORE_DRILL.md` — backup restore procedure (26/26 tables verified)
- `docs/GO_LIVE_AUG1.md` — audited cutover list

## Product / spec
- `docs/GOAL.md`, `docs/TECHNICAL.md`, `docs/USER_GUIDE.md`, `docs/ADMIN_GUIDE.md`
- `docs/Trucking_CSuite_Owner_Playbook*.docx` — the 1000-metric C-suite spec (see [[csuite-playbook]])
- `docs/CODE_REVIEW_2026-07-21.md` — the 6-pass review that seeded the 48h backlog

## Key code paths
- **Sentinel** (the proactive brain): `supabase/migrations/*sentinel*` — full `sentinel_scan()` redefined per migration; see [[engineering-conventions]] for the splice pattern.
- **Agent catalog**: `supabase/functions/_shared/truxcore.ts` — the tool list Forest sees.
- **Edge auth/shared**: `supabase/functions/_shared/auth.ts` — `requireCron`, `getCaller`, `withCors`, `timingSafeEqualStr`, `mintUserSession/mintAdminSession`, `listAllAuthUsers`.
- **Frontend data layer**: `frontend/src/data.ts` (all RPC wrappers). Pages in `frontend/src/pages/`. Security console: `pages/Security.tsx`; shared MFA card: `components/MfaCard.tsx`.
- **Mobile**: `mobile/lib/` — session in `services/secure_session.dart` + `session_store.dart` (keystore-backed); tracking in `services/tracking_service.dart`.
- **Tests**: `supabase/tests/NN_*.sql` (pgTAP), `mobile/test/` (Dart), `.github/workflows/ci.yml`.

## Machine / toolchain
See [[user-ilker]] and [[nas-access]]. Flutter `~/sdk/flutter`, Android SDK `~/sdk/android`, Supabase CLI `~/.local/bin/supabase`, Deno `~/.deno/bin/deno`, local DB port 54322 (pw `postgres`).

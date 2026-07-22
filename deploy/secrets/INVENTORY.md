# Truxon Secrets Inventory

The checklist of **what** to store in the vault and **where each currently lives** — so nothing is forgotten. **No values here, ever** (this file is committed to git). Values live only in `truxon-secrets.kdbx`.

Groups match the vault structure: `Truxon/{Supabase, Mobile-Signing, NAS, Integrations, Infra, Accounts}`.

Legend: 🔴 critical (loss hurts) · 🟡 important · 🟢 public-safe (store for completeness) · ⏳ not issued yet.

## Truxon/Supabase
| Entry | 🔺 | Currently lives | Notes |
|---|---|---|---|
| `service_role key (prod)` | 🔴 | Supabase dashboard; NAS `backup.env`; re-fetch `supabase projects api-keys` | RLS-bypassing — the crown-jewel key |
| `CRON_SECRET` | 🔴 | Supabase edge secrets + DB `app_private.cron_config` | rotate via `secrets set` + watchdog setter |
| `DB password (prod)` | 🔴 | Supabase dashboard (Database settings) | direct-connection / `postgres` role |
| `anon / publishable key` | 🟢 | `frontend/.env.local`, `mobile/build-apk.sh` (in git) | public-safe; store so it's all in one place |
| `SUPABASE_ACCESS_TOKEN` (CLI) | 🟡 | `supabase login` on this box | personal CLI token |

## Truxon/Mobile-Signing  ← closes the DR single-point-of-failure
| Entry | 🔺 | Currently lives | Notes |
|---|---|---|---|
| `truxon-release.jks` (attach the file) | 🔴 | `~/dev-tools/truxon-release.jks`; NAS `release-signing/signing-*.tar.gz` | **attach the .jks as a file to this entry** — then a B2/offsite copy of the vault = the signing key is finally offsite |
| `keystore storePassword` | 🔴 | `mobile/android/key.properties` (gitignored) | |
| `key alias + keyPassword` | 🔴 | `mobile/android/key.properties` | lose these + the .jks = whole fleet re-key |

## Truxon/NAS
| Entry | 🔺 | Currently lives | Notes |
|---|---|---|---|
| `NAS SSH` (host/user + key or password) | 🔴 | this box's SSH; host `turkyildiz@100.89.140.98` | Tailscale + Funnel `aida-nas.tail2c5ca.ts.net` |
| `BACKUP_PASSPHRASE` (GPG) | 🔴 | NAS `backup.env` | decrypts every DB backup — without it backups are useless |
| `B2_KEY_ID` / `B2_APP_KEY` | 🔴 | NAS `b2.env` | Backblaze offsite |
| `B2_BUCKET` / `B2_ENDPOINT` / `B2_REGION` | 🟡 | NAS `b2.env` | |

## Truxon/Integrations
| Entry | 🔺 | Currently lives | Notes |
|---|---|---|---|
| `QBO / Intuit` client id + secret + realm | 🔴 | Supabase edge secrets; Intuit developer portal | OAuth tokens themselves live in the DB |
| `Microsoft Graph` tenant/client id + client secret | 🔴 | Supabase edge secrets (`msgraph`) | forest@ mailbox access |
| `ELB (ElevenLabs) API key` | 🟡 | Supabase edge secret (`trux-tts`) | Forest's voice |
| `LLM_API_KEY` (agent/extraction) | 🟡 | Supabase edge secret | OpenRouter-style key |
| `FCM / Firebase` (push) | 🟡 | Supabase edge secret; `google-services.json` | driver alarms |
| `PrePass SFTP` host/user/pass + `PREPASS_HOSTKEY` | 🟡 | NAS `tolls.env` | toll pull |
| `AtoB fuel` login | 🟡 | NAS fuel job env | fuel CSV pull |
| `Denim factoring API key` | ⏳ | not issued yet | pending owner |
| `ELD DriveHOS company/API key` | ⏳ | not issued yet | pending Aida's key |
| `TOLL_SYNC_KEY` / `FUEL_IMPORT_KEY` / `WATCHDOG_REPORT_KEY` / `NOTIFY_WEBHOOK_SECRET` / `LEGACY_WORKER_KEY` | 🟡 | Supabase edge secrets | per-door shared keys |

## Truxon/Infra
| Entry | 🔺 | Currently lives | Notes |
|---|---|---|---|
| `Vercel` deploy token (if any) | 🟡 | Vercel (mostly via GitHub integration) | |
| `GitHub PAT` (releases/CI, if any) | 🟡 | GitHub settings | OTA APK publishing to `truxon-releases` |
| `Domain / DNS` (truxon.com registrar) | 🟡 | registrar account | |
| `llm-proxy bearer` (NAS Funnel) | 🟡 | NAS `proxy.env` | |

## Truxon/Accounts (login credentials)
Supabase · Vercel · Intuit developer · Backblaze · Microsoft 365 admin · Google (turkyildiz@gmail.com) · GitHub · registrar · ElevenLabs. Store login + **MFA recovery codes** for each.

---
**After populating:** run `deploy/secrets/secrets-sync.sh push`, then arrange one **offsite** copy of the .kdbx (README). Update this list whenever a new secret is introduced.

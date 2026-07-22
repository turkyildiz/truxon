# Threat model: JadePuffer / ENCFORGE (agentic ransomware)

**What it is.** JadePuffer (Sysdig TRT, July 2026) is the first documented *agentic*
ransomware: an LLM agent drives the entire kill-chain — recon, credential theft,
lateral movement, privilege escalation, persistence, and destruction — at machine
speed (failed login to working fix in 31 seconds). Its ENCFORGE payload targets the
AI/ML stack (model checkpoints, vector DBs, embedding indices) and production
databases, encrypting then dropping them.

**Why Truxon is in the target profile.** A production Postgres database, a self-hosted
AI/ML stack (Ollama, vision models, doc embeddings on the NAS), internet-facing
services, and API keys in service environments. The value of this doc is a stage-by-stage
map of *their* kill-chain onto *our* surface, and what blocks each step.

## Kill-chain → Truxon exposure → defense

| Stage | JadePuffer move | Truxon exposure | Defense (status) |
|---|---|---|---|
| **Initial access** | RCE in internet-facing Langflow (CVE-2025-3248) | **No Langflow / Nacos / MinIO anywhere** (verified). Ollama binds `127.0.0.1` only. Funnel surface = token-gated llm-proxy + read-only Valhalla. | ✅ Vectors absent; minimal, authenticated Funnel surface |
| **Recon / secret sweep** | Reads env vars for LLM+cloud+DB keys | Edge-function envs hold the **service key**; NAS `backup.env`/compose hold service key + DB URL + backup passphrase | ⚠️ Partial — **canary env token** (`LEGACY_WORKER_KEY`) trips on replay; residual risk = NAS secrets in plaintext compose (see below) |
| **Object storage w/ default creds** | `minioadmin:minioadmin` on MinIO | Supabase Storage is authed; no MinIO | ✅ N/A |
| **Persistence** | Cron beacon to C2 every 30 min | NAS cron/containers | ⚠️ IOC egress block script (`deploy/security/ioc-block.sh`) — owner must apply (no passwordless sudo) |
| **Lateral → prod DB** | Harvested creds → production DB | Service key → Supabase Postgres | ✅ Honeytokens catch decoy-key replay; audit log records access |
| **Priv-esc / backdoor admin** | Inject admin row into auth tables | Insert/elevate a `profiles` admin | ✅ **Role-escalation tripwire** (critical audit + push); **lockdown** freezes role changes |
| **Destruction** | `AES_ENCRYPT` then `DROP DATABASE` / `DROP TABLE` / TRUNCATE | Same, via the service key | ✅ **Ransomware guard**: event trigger blocks DROP TABLE/SCHEMA + TRUNCATE on business tables, alarms out-of-band (survives rollback). Service key/authenticator *cannot* remove it (event-trigger ownership) |
| **Recovery denial** | Claims data already exfiltrated; destroys backups | Backups | ✅ 3 copies; NAS + B2 out of cloud attacker's reach (see below) |

## Backup posture (the recovery guarantee)

Three copies, so encryption/deletion of prod is survivable:
1. **Supabase prod** (live).
2. **NAS-local** — `truxon-backup` container *pulls* nightly `pg_dump` + storage tar,
   GPG-AES256 encrypted, 30-day retention. **Pull-based**, so a cloud/service-key
   compromise cannot reach in to delete them.
3. **Backblaze B2** — offsite copy.

**Resilient to:** a cloud / service-key compromise (stages above) — the NAS and B2
copies are unreachable from there, and the DB guard blocks the destruction anyway.

**Residual risk (honest):** if the **NAS itself** is compromised, it holds the service
key, DB URL, backup passphrase, the B2 key, *and* the local backups — a single point
that could reach all three. The NAS also runs several internet-facing media services
(Plex/Sonarr/Radarr/Sabnzbd/Jellyfin/Mumble) that are potential initial-access vectors
sitting next to the backup vault.

## Owner action items (need you / can't do headless)

1. **B2 Object Lock** — enable immutable retention (compliance/governance lock) on the
   B2 bucket so backups can't be deleted *even with the B2 key*. This is THE
   anti-ransomware backup control and closes the NAS-compromise gap.
2. **Move NAS secrets out of `docker-compose.yaml`** — the service key + backup
   passphrase + B2 keys are inline `environment:` values (plaintext). Switch to
   `env_file:` with a root-owned `600` file; keep them out of any world-readable path.
3. **Reduce NAS surface** — the media stack shares a host with the backup vault and the
   service key. Isolate the Truxon backup/AI containers (separate host or at least
   separate secrets not co-readable by the media apps), or firewall the media services
   off the internet.
4. **Apply the IOC block** — `sudo sh deploy/security/ioc-block.sh` on the NAS (+ boot
   task to persist).
5. **MFA on office accounts** — still the highest-value single control (already tracked).

## If it happens (see also deploy/SECURITY_RUNBOOK.md)

A `🧨 Blocked a destructive operation` or `🍯 Decoy credential replayed` finding = active
intrusion. Response: `set_lockdown(true, ...)` → full read-only freeze (runbook §2) →
`security_audit_verify()` + `security_audit_recent()` → rotate service key + DB password
+ B2 key → restore from the NAS/B2 backup if any data was touched.

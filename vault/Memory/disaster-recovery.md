---
name: disaster-recovery
description: "What survives if the dev box dies — production is cloud-safe; the one residual single-point-of-failure is the app signing key (NAS-only, not offsite)"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 7541d708-7353-4f10-878c-db1e3485f192
---

DR map, audited 2026-07-22 ("what happens if this computer dies?").

**LIVE DR + cyber-recovery DRILL 2026-07-23 — results:** (1) **DB restore drill PASSED** — newest encrypted dump (`db_20260723`) decrypted with `BACKUP_PASSPHRASE` + restored into a throwaway Postgres, asserting real rows (11 profiles / 984 loads / 232 customers / 2498 documents / 10861 storage objects; the ~150 pg_restore errors are expected role/extension noise). (2) **Signing-key DR PROVEN** — decrypted all three copies (dev box, NAS, Supabase `dr-vault`) → keystore sha256 `4541d893…` **byte-identical across all three**, each bundle has `.jks` + `key.properties`. SPOF genuinely closed. (3) **Security posture strong** — `security_audit_verify` hash-chain intact (11/11), `security_console` `guard_armed:true / lockdown:false`, all ransomware guards armed on every crown-jewel table (DDL-drop, per-table truncate, bulk-delete/update), profiles last-admin protection now covers DELETE too. NOTE: verified guards read-only (never live-fired on prod — the OOB dblink alarm survives rollback and pages). (4) **Found + FIXED the one real gap:** offsite INDIANCREEK rsync was broken — see [[offsite-nas]] (pinned sibling rsync image). Remaining follow-up: the `offsite_fresh` watchdog check didn't fire during the outage (monitoring gap).

**Production is unaffected.** Truxon runs on **Supabase (cloud)** + **Vercel (cloud)**, deployed from GitHub — none of it runs on the dev box. The prod DB has 3-copy backups (Supabase / NAS 30-day GPG pull / Backblaze B2). So a dead dev box does **not** take the business down.

**Recoverable from GitHub** (verified local `main` == `origin/main`, clean, no stashes/unpushed): all code, migrations, edge functions, the **vault** (memory + rules + reports + readable session logs), docs. On a new box: `git clone`, then re-link memory: `ln -s <repo>/vault/Memory ~/.claude/projects/-home-ilker-DEV/memory`, reinstall Obsidian + Supabase/Flutter toolchain.

**Off the dev box but recoverable** (on the NAS, survives a dev-box death): the **app signing key** — `/volume1/docker/truxon-backup/release-signing/signing-2026-07-21b.tar.gz(.gpg)` contains BOTH `truxon-release.jks` + `key.properties` (complete). NAS `backup.env` holds the service key + backup passphrase + B2 keys. Supabase CLI link/keys re-fetch via `supabase login`.

**Actually LOST if the dev box dies:**
- Raw session transcripts (`vault/Sessions/raw/*.jsonl.gz`) — local/gitignored by design. Readable session summaries survive on GitHub.
- `frontend/.env.local` (anon key — public-safe, also in build-apk.sh), `deploy/drive-import/drive.env` (regenerable). Low impact.

**~~THE RESIDUAL SINGLE-POINT-OF-FAILURE~~ — CLOSED 2026-07-22:** the signing bundle was **NAS-only**, so dev-box + NAS double-loss = signing key gone = **whole fleet re-key** (task #109). **Fixed:** the GPG-encrypted `signing-2026-07-21b.tar.gz.gpg` is now uploaded to a **private Supabase Storage bucket `dr-vault`** (`dr-vault/release-signing/…`, cloud → survives dev-box+NAS loss; verified byte-identical sha256). The nightly backup (`scripts/backup.sh` on the NAS + repo `deploy/backup/backup.sh`) re-mirrors `release-signing/*.gpg` to `dr-vault` every run, so future key rotations stay offsite automatically. Retrieve: download `dr-vault/release-signing/*.gpg` with the service key, `gpg -d` with `BACKUP_PASSPHRASE`.
 **Still worth doing (belt+suspenders):** the KeePassXC [[secrets-vault]] (owner-run) for a *second* offsite + all other secrets; and drop a copy in a personal cloud. **⚠ FLAG:** an **unencrypted** `signing-2026-07-21b.tar.gz` (the raw .jks) sits next to the .gpg on the NAS — nothing references it; safe to delete (the .gpg + passphrase reproduce it). Related: [[nas-access]], [[security-posture]], [[release recovery]].

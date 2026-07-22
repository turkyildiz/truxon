---
name: disaster-recovery
description: "What survives if the dev box dies — production is cloud-safe; the one residual single-point-of-failure is the app signing key (NAS-only, not offsite)"
metadata:
  type: reference
---

DR map, audited 2026-07-22 ("what happens if this computer dies?").

**Production is unaffected.** Truxon runs on **Supabase (cloud)** + **Vercel (cloud)**, deployed from GitHub — none of it runs on the dev box. The prod DB has 3-copy backups (Supabase / NAS 30-day GPG pull / Backblaze B2). So a dead dev box does **not** take the business down.

**Recoverable from GitHub** (verified local `main` == `origin/main`, clean, no stashes/unpushed): all code, migrations, edge functions, the **vault** (memory + rules + reports + readable session logs), docs. On a new box: `git clone`, then re-link memory: `ln -s <repo>/vault/Memory ~/.claude/projects/-home-ilker-DEV/memory`, reinstall Obsidian + Supabase/Flutter toolchain.

**Off the dev box but recoverable** (on the NAS, survives a dev-box death): the **app signing key** — `/volume1/docker/truxon-backup/release-signing/signing-2026-07-21b.tar.gz(.gpg)` contains BOTH `truxon-release.jks` + `key.properties` (complete). NAS `backup.env` holds the service key + backup passphrase + B2 keys. Supabase CLI link/keys re-fetch via `supabase login`.

**Actually LOST if the dev box dies:**
- Raw session transcripts (`vault/Sessions/raw/*.jsonl.gz`) — local/gitignored by design. Readable session summaries survive on GitHub.
- `frontend/.env.local` (anon key — public-safe, also in build-apk.sh), `deploy/drive-import/drive.env` (regenerable). Low impact.

**THE RESIDUAL SINGLE-POINT-OF-FAILURE:** the signing bundle is **NAS-only — NOT shipped to B2 offsite.** So dev-box death is fine, but **dev box + NAS both lost** (fire/theft/ransomware hitting both) = signing key gone = **whole fleet must re-key** (every tablet re-sideloads a fresh-keyed APK; OTA to existing installs breaks — they've been through this once, task #109). Fix: put the GPG-encrypted `signing-*.tar.gz.gpg` somewhere offsite (B2, a password manager, or personal cloud). Owner action. Related: [[nas-access]], [[security-posture]], [[release recovery]].

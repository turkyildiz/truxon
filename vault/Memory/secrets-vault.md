---
name: secrets-vault
description: "All Truxon secrets go in a KeePassXC .kdbx — NAS primary + local backup (+ offsite); tooling in deploy/secrets; owner holds the master password"
metadata:
  type: reference
---

The single home for **all Truxon secrets** is a **KeePassXC** vault, `truxon-secrets.kdbx` (AES-256; upgrade KDF to Argon2id in the GUI). Set up 2026-07-22. No running server (minimal attack surface).

**Locations (all encrypted at rest):** local working `~/dev-tools/secrets/truxon-secrets.kdbx` + `backups/` · NAS primary `/volume1/docker/truxon-backup/secrets/truxon-secrets.kdbx` + `versions/` · recommended offsite = the NAS nightly B2 sweep (the secrets/ dir sits under the backed-up path).

**App + tooling:** KeePassXC 2.7.12 installed (AppImage at `~/Applications/keepassxc`, GUI launcher + `keepassxc-cli` symlinked to `~/.local/bin`). Version-controlled scripts in `deploy/secrets/`: `secrets-init.sh` (owner creates the vault — types the master password, never Claude), `secrets-sync.sh {push|pull|status}` (NAS↔local via `ssh cat`, NOT scp — Synology SFTP is chrooted and fails on absolute /volume1 paths), `INVENTORY.md` (the full name+location map of every secret, **no values**), `README.md`. `.kdbx` is gitignored — never committed.

**Boundary:** Claude never sets/sees the master password and never handles secret VALUES — the owner populates entries (GUI) and runs `secrets-init.sh`. Claude built the install, dirs (700), sync (round-trip self-tested byte-identical with a throwaway vault, then cleaned), inventory, and docs.

**Closes the DR gap** from [[disaster-recovery]]: attaching `truxon-release.jks` + the key.properties values to the vault, then getting the vault offsite, finally puts the **app signing key offsite** (was NAS-only → a dev-box+NAS double loss would have forced a fleet re-key). Related: [[nas-access]], [[security-posture]], [[disaster-recovery]].

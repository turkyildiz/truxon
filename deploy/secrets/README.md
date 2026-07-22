# Truxon Secrets Vault

A single **KeePassXC** database (`truxon-secrets.kdbx`) — AES-256, one master password (upgrade KDF to Argon2id in the GUI — see below), no running server. Holds every Truxon secret in one encrypted file that lives on the **NAS** (primary) with a **local** working copy + backups, and (recommended) an **offsite** copy. Closes the DR gaps from [[disaster-recovery]] (incl. the app signing key finally getting offsite).

> **The master password is yours alone.** Claude never sets or sees it, and never enters secret *values*. This tooling builds everything *around* that.

## One-time setup (you run these)
```bash
# 1. Create the vault — you'll type a strong master password (twice).
deploy/secrets/secrets-init.sh

# 2. Open it and add entries (values live ONLY here). GUI is easiest:
keepassxc ~/dev-tools/secrets/truxon-secrets.kdbx     # or the app menu → KeePassXC
#    → create groups Truxon/{Supabase,Mobile-Signing,NAS,Integrations,Infra,Accounts}
#    → add each entry from deploy/secrets/INVENTORY.md
#    → attach ~/dev-tools/truxon-release.jks to Truxon/Mobile-Signing (the DR fix)

# 3. Back it up (NAS primary + local timestamped backup):
deploy/secrets/secrets-sync.sh push
```

## Day-to-day
```bash
deploy/secrets/secrets-sync.sh push     # after any change → NAS + local backup
deploy/secrets/secrets-sync.sh pull     # bring the NAS copy down (e.g. new machine)
deploy/secrets/secrets-sync.sh status   # where the copies are + timestamps
keepassxc-cli show ~/dev-tools/secrets/truxon-secrets.kdbx "Truxon/Supabase/service_role"  # read one
```
Mobile: install **KeePassDX** (Android) and keep a copy of the `.kdbx` on the phone (or open the NAS copy). Same master password.

## Where copies live
| Copy | Path | Encrypted | Off-box |
|---|---|---|---|
| Local working | `~/dev-tools/secrets/truxon-secrets.kdbx` | ✅ | — |
| Local backups | `~/dev-tools/secrets/backups/…-<ts>.kdbx` | ✅ | — |
| **NAS primary** | `/volume1/docker/truxon-backup/secrets/truxon-secrets.kdbx` | ✅ | ✅ |
| NAS versions | `…/secrets/versions/…-<ts>.kdbx` | ✅ | ✅ |
| **Offsite (B2)** — recommended | see below | ✅ | ✅✅ |

## Offsite (do one)
The `.kdbx` is already encrypted, so any offsite location is safe:
- **Simplest:** the NAS nightly backup already ships `/volume1/docker/truxon-backup/…` to Backblaze B2 — confirm `secrets/` is in that sweep (it lives under that dir now), or add it. Then the vault (and the attached signing key) is offsite automatically.
- **Or manual:** drop the `.kdbx` in a personal cloud / a second USB kept elsewhere.

## Hardening options (optional)
- **Key file (2FA on the vault):** `secrets-init.sh` can also take `--set-key-file` — password *and* a key file both required to open. Keep the key file only on trusted machines (not next to the .kdbx). Stronger, but must be present wherever you open the vault.
- **YubiKey/challenge-response** if you use one.

## Never
- Never commit a `.kdbx` (gitignored here). Never put values in `INVENTORY.md`. Never share the master password over chat/email.

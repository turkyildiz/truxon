#!/usr/bin/env bash
# Create the Truxon secrets vault (KeePassXC .kdbx).
# YOU choose + type the master password — this script never sees or sets it.
# Run once, then add entries in the KeePassXC GUI (or `keepassxc-cli add`).
set -euo pipefail

DB="${SECRETS_DB:-$HOME/dev-tools/secrets/truxon-secrets.kdbx}"
CLI="$(command -v keepassxc-cli || echo "$HOME/.local/bin/keepassxc-cli")"
[ -x "$CLI" ] || { echo "keepassxc-cli not found (install KeePassXC first)"; exit 1; }
mkdir -p "$(dirname "$DB")"; chmod 700 "$(dirname "$DB")"

if [ -f "$DB" ]; then
  echo "vault already exists: $DB  (nothing to do)"; exit 0
fi

echo "Creating $DB"
echo "  → You'll be prompted for a STRONG master password (typed twice)."
echo "  → Use a long passphrase you can remember but nobody can guess. Write it"
echo "    down offline ONCE (paper in a safe) — if it's lost, the vault is gone."
echo
# --decryption-time tunes the KDF to ~1.5s of work on this box (strong).
# NOTE: the CLI creates an AES-KDF vault; for the memory-hard Argon2id KDF
# (best-in-class), open Database → Database Settings → Security in the GUI and
# switch KDF to Argon2id (one click). Password is set interactively below.
"$CLI" db-create "$DB" --set-password --decryption-time 1500
chmod 600 "$DB"
echo
echo "Vault created (AES-256; KDF tuned to ~1.5s)."
echo "  ↳ For the strongest KDF, open it in the GUI → Database Settings → Security"
echo "    → set KDF = Argon2id.  (Memory-hard = far harder to brute-force.)"
echo
echo "Next:"
echo "  1) Open it:   keepassxc  ~/dev-tools/secrets/truxon-secrets.kdbx   (or the app menu)"
echo "  2) Create groups Truxon/{Supabase,Mobile-Signing,NAS,Integrations,Infra,Accounts}"
echo "     and add the entries listed in deploy/secrets/INVENTORY.md (values are ONLY in the vault)."
echo "  3) Back it up:  deploy/secrets/secrets-sync.sh push   (→ NAS primary + local backup)"

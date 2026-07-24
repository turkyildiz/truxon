#!/usr/bin/env bash
# Attach FILE-based secrets (signing keys, keystores, configs) to the KeePassXC
# vault as entry attachments — so an offsite copy of the .kdbx carries them too
# (this is the DR fix: the signing keys finally live somewhere other than one box).
#
#   deploy/secrets/vault-add-files.sh
#
# No secret VALUES live in this script. keepassxc-cli reads each file directly,
# and YOU type the master password at each prompt — Claude never sees it, per the
# vault's design (README). Idempotent: re-running overwrites the attachment (-f)
# and keeps any existing entry/notes. You WILL be prompted for the master
# password several times (once per keepassxc-cli call) — that's normal for the
# CLI; the GUI is a one-unlock alternative (drag the files onto the entries).
#
# After it succeeds AND you've opened the vault and SEEN the OTA key inside:
#   deploy/secrets/secrets-sync.sh push          # back up to NAS + local
#   shred -u /home/ike/TRUXON/truxon-ota-signing.pem   # remove the on-disk key
set -uo pipefail

DB="${TRUXON_VAULT:-$HOME/dev-tools/secrets/truxon-secrets.kdbx}"
[ -f "$DB" ] || { echo "vault not found: $DB (run deploy/secrets/secrets-init.sh first)"; exit 1; }
CLI="$(command -v keepassxc-cli)" || { echo "keepassxc-cli not found"; exit 1; }

OTA_PUB="7wgHZViaf7zP/9LgWNq9SK3pnigFQlIo4PjNcPPs11Q="

# GROUP|ENTRY|FILE|NOTES  (paths only — never values)
rows=(
  "Truxon/Mobile-Signing|OTA-manifest-signing-key|/home/ike/TRUXON/truxon-ota-signing.pem|Ed25519 OTA manifest signing (PRIVATE). Public key embedded in mobile/lib/config.dart: ${OTA_PUB}. Signed by publish-release.sh via TRUX_OTA_SIGNING_KEY. Rotate: new pair -> update config.dart pubkey -> ship that build -> then sign with the new key."
  "Truxon/Mobile-Signing|truxon-release-keystore|/home/ike/dev-tools/truxon-release.jks|Android upload keystore (.jks). Losing this + its passwords = the whole fleet must re-key. storePassword / keyPassword / alias live in mobile/android/key.properties — add those as separate TEXT entries via the GUI."
  "Truxon/Integrations|FCM-google-services|/home/ike/TRUXON/mobile/android/app/google-services.json|Firebase push config. Public-safe but not in git; losing it blocks APK builds until re-downloaded from the Firebase console."
)

cat <<'BANNER'
------------------------------------------------------------------------------
keepassxc-cli will ask for your MASTER PASSWORD on each step below (it prints
"Enter password to unlock ...").  Type it and press Enter each time.  Seeing
"Group ... already exists" or "Entry ... already exists" is EXPECTED and
harmless — the script keeps going.  (stderr is intentionally NOT hidden here, so
the password prompt is always visible.)
------------------------------------------------------------------------------
BANNER

# Ensure parent groups exist (the "already exists" message is fine).
for g in "Truxon" "Truxon/Mobile-Signing" "Truxon/Integrations"; do
  "$CLI" mkdir "$DB" "$g" || true
done

added=0
for row in "${rows[@]}"; do
  IFS='|' read -r group entry file notes <<<"$row"
  path="$group/$entry"
  if [ ! -f "$file" ]; then echo "-- skip $path (file absent: $file)"; continue; fi
  echo ">> $path"
  # Create the entry if missing (add errors when it already exists — tolerate).
  "$CLI" add "$DB" "$path" --notes "$notes" || echo "   ($path already exists — keeping it)"
  if "$CLI" attachment-import -f "$DB" "$path" "$(basename "$file")" "$file"; then
    echo "== attached $(basename "$file")  ->  $path"
    added=$((added+1))
  else
    echo "!! failed to attach $(basename "$file") -> $path"
  fi
done

echo
echo "Attached $added file(s)."
echo "Next:  deploy/secrets/secrets-sync.sh push        # NAS + local backup"
echo "Then, once you've OPENED the vault and confirmed the OTA key is inside:"
echo "       shred -u /home/ike/TRUXON/truxon-ota-signing.pem"

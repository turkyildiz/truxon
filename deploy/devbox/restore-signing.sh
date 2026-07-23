#!/usr/bin/env bash
# Restore the release-signing keystore + key.properties from the NAS onto this box.
# Prereq: NAS SSH works (ssh-copy-id done). Idempotent.
#   bash deploy/devbox/restore-signing.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAS="${SECRETS_NAS:-turkyildiz@100.89.140.98}"
BUNDLE_DIR="/volume1/docker/truxon-backup/release-signing"

mkdir -p ~/dev-tools && cd ~/dev-tools
# UGOS scp/rsync are broken — tar-over-ssh is the only reliable transfer.
bundle=$(ssh "$NAS" "ls -1t $BUNDLE_DIR/signing-*.tar.gz | head -1")
echo "restoring $(basename "$bundle") …"
ssh "$NAS" "tar czf - -C $BUNDLE_DIR $(basename "$bundle")" | tar xzf -
tar xzf "$(basename "$bundle")"
chmod 600 truxon-release.jks key.properties
# storeFile inside key.properties is an absolute path from whichever box made the
# bundle — rewrite it for THIS home dir.
sed -i "s|^storeFile=.*|storeFile=$HOME/dev-tools/truxon-release.jks|" key.properties
mv key.properties "$REPO/mobile/android/key.properties"

# Verify the cert is the fleet key (same-key = OTA continuity; wrong key = STOP)
STOREPASS=$(grep -oP '^storePassword=\K.*' "$REPO/mobile/android/key.properties")
fp=$(~/sdk/jdk17/bin/keytool -list -v -keystore truxon-release.jks -storepass "$STOREPASS" 2>/dev/null \
  | grep -oP 'SHA256: \K.*' | head -1)
echo "cert SHA-256: $fp"
case "$fp" in
  3F:9D:34:BC:*) echo "✓ fleet certificate confirmed — release builds will OTA cleanly" ;;
  *) echo "✗ FINGERPRINT MISMATCH — do NOT publish; expected 3F:9D:34:BC:…"; exit 1 ;;
esac

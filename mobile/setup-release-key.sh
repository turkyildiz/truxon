#!/usr/bin/env bash
# One-shot: create the release keystore AND key.properties from a single
# password prompt, so the two can never disagree. Safe to re-run (it recreates).
#
#   ./setup-release-key.sh
#
# The password is read hidden, never echoed, never written to shell history.
# Keep it in your password manager — it can NEVER change or OTA updates break.
set -euo pipefail
cd "$(dirname "$0")"

KEYTOOL="$HOME/dev-tools/jdk17/bin/keytool"
JKS="android/truxon-release.jks"
PROPS="android/key.properties"
ALIAS="truxon"

read -r -s -p "Choose a keystore password: " PW; echo
read -r -s -p "Re-enter to confirm:        " PW2; echo
if [[ "$PW" != "$PW2" ]]; then echo "Passwords do not match — aborting."; exit 1; fi
if [[ -z "$PW" ]]; then echo "Empty password — aborting."; exit 1; fi

# Fresh keystore every run so state can't drift.
rm -f "$JKS"
"$KEYTOOL" -genkeypair -v \
  -keystore "$JKS" \
  -storepass "$PW" -keypass "$PW" \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -alias "$ALIAS" \
  -dname "CN=Truxon, OU=Fleet, O=Truxon, L=, ST=, C=US"

# Write key.properties with the SAME password. gitignored; storeFile is
# relative to android/ (the Gradle rootProject).
cat > "$PROPS" <<EOF
storePassword=$PW
keyPassword=$PW
keyAlias=$ALIAS
storeFile=truxon-release.jks
EOF

# Prove the password works before we hand back.
if "$KEYTOOL" -list -keystore "$JKS" -storepass "$PW" >/dev/null 2>&1; then
  echo "✓ Keystore + key.properties created and password verified."
else
  echo "✗ Verification failed — check $KEYTOOL and try again."; exit 1
fi

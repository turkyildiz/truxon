#!/usr/bin/env bash
# Publish a new Trux Companion release so every installed tablet self-updates.
#
#   ./publish-release.sh "What changed in this build"
#
# It bumps the build number, builds a release APK, and creates a GitHub Release
# in the PUBLIC repo below with two assets: the APK and a latest.json. The app
# reads github.com/<repo>/releases/latest/download/latest.json on launch and
# offers the update. No thumb drive, no Play Store.
#
# One-time setup (see RELEASES.md): install gh, `gh auth login`, and
#   gh repo create turkyildiz/truxon-releases --public --add-readme
set -euo pipefail
cd "$(dirname "$0")"

# gh + flutter wherever this box keeps them (release machine used ~/dev-tools;
# the dev box uses ~/.local/bin + ~/sdk/flutter). truxon-env.sh is optional.
GH="$(command -v gh || echo "$HOME/dev-tools/gh")"
[ -f "$HOME/dev-tools/truxon-env.sh" ] && source "$HOME/dev-tools/truxon-env.sh"
for f in "$HOME/dev-tools/flutter/bin" "$HOME/sdk/flutter/bin"; do
  [ -d "$f" ] && export PATH="$f:$PATH"
done
REPO="turkyildiz/truxon-releases"
NOTES="${1:-Update}"
# R9 #151 — staged rollout: ROLLOUT=25 ./publish-release.sh "notes" offers the
# build to ~25% of tablets (stable per-device buckets). Re-publish latest.json
# with a higher pct to widen the wave. Default 100 = everyone.
ROLLOUT="${ROLLOUT:-100}"
case "$ROLLOUT" in (*[!0-9]*|'') echo "ROLLOUT must be 0-100"; exit 1;; esac
[ "$ROLLOUT" -le 100 ] || { echo "ROLLOUT must be 0-100"; exit 1; }

# 1) bump versionCode:  1.0.0+N  ->  1.0.0+(N+1)
line=$(grep -m1 '^version:' pubspec.yaml)
name=$(sed -E 's/version:[[:space:]]*([0-9.]+)\+([0-9]+).*/\1/' <<<"$line")
code=$(sed -E 's/version:[[:space:]]*([0-9.]+)\+([0-9]+).*/\2/' <<<"$line")
newcode=$((code + 1))
sed -i -E "s/^version:.*/version: ${name}+${newcode}/" pubspec.yaml
echo "==> version ${name}+${newcode} (versionCode ${newcode})"

# 2) build the release APK
./build-apk.sh release
# Give the asset its FINAL filename. `gh release create path#Label` only sets a
# display label, NOT the download filename — the /latest/download/ URL always
# uses the real basename. So the file must actually be named TruxCompanion.apk,
# or latest.json's apkUrl 404s and OTA silently fails.
cp "build/app/outputs/flutter-apk/app-release.apk" "build/app/outputs/flutter-apk/TruxCompanion.apk"
APK="build/app/outputs/flutter-apk/TruxCompanion.apk"

# 3) latest.json — apkUrl uses the stable /latest/ path so it always points
# here. sha256 lets the app verify the download before installing; the app
# refuses any APK that doesn't match (or a manifest without the field).
APKURL="https://github.com/${REPO}/releases/latest/download/TruxCompanion.apk"
SHA256=$(sha256sum "$APK" | cut -d' ' -f1)

# 3a) SIGN the manifest (Ed25519). The app embeds our public key and refuses a
# manifest that isn't validly signed — so a compromised release host can't forge
# a downgrade or redirect the APK, the gap sha256-in-the-same-manifest can't
# close. The private key never lives in the repo: point TRUX_OTA_SIGNING_KEY at
# the PEM you export from the vault at release time (then shred it). The signed
# payload is the security-critical fields, newline-joined, IDENTICAL to the
# app's canonicalManifestPayload(): versionCode, versionName, apkUrl, sha256,
# rolloutPct.
: "${TRUX_OTA_SIGNING_KEY:?set TRUX_OTA_SIGNING_KEY to your ed25519 PEM path (export from KeePassXC at release, shred after). See RELEASES.md.}"
[ -f "$TRUX_OTA_SIGNING_KEY" ] || { echo "signing key not found: $TRUX_OTA_SIGNING_KEY"; exit 1; }
PAYLOAD_FILE="$(mktemp)"
SIG_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE" "$SIG_FILE"' EXIT
printf '%s\n%s\n%s\n%s\n%s' "$newcode" "$name" "$APKURL" "$SHA256" "$ROLLOUT" > "$PAYLOAD_FILE"
openssl pkeyutl -sign -inkey "$TRUX_OTA_SIGNING_KEY" -rawin -in "$PAYLOAD_FILE" -out "$SIG_FILE"
SIG=$(base64 -w0 < "$SIG_FILE")
[ "$(wc -c < "$SIG_FILE")" = "64" ] || { echo "unexpected signature length — is the key ed25519?"; exit 1; }
echo "==> manifest signed (ed25519, 64-byte sig)"

cat > /tmp/latest.json <<JSON
{ "versionCode": ${newcode}, "versionName": "${name}", "apkUrl": "${APKURL}", "sha256": "${SHA256}", "rolloutPct": ${ROLLOUT}, "sig": "${SIG}", "notes": "${NOTES//\"/\\\"}" }
JSON

# 4) publish the GitHub release with both assets
TAG="v${name}+${newcode}"
"$GH" release create "$TAG" \
  "${APK}" \
  "/tmp/latest.json" \
  --repo "$REPO" --title "$TAG" --notes "$NOTES"

echo "==> published ${TAG}. Tablets will offer this on next launch."

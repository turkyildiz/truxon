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
cat > /tmp/latest.json <<JSON
{ "versionCode": ${newcode}, "versionName": "${name}", "apkUrl": "${APKURL}", "sha256": "${SHA256}", "notes": "${NOTES//\"/\\\"}" }
JSON

# 4) publish the GitHub release with both assets
TAG="v${name}+${newcode}"
"$GH" release create "$TAG" \
  "${APK}" \
  "/tmp/latest.json" \
  --repo "$REPO" --title "$TAG" --notes "$NOTES"

echo "==> published ${TAG}. Tablets will offer this on next launch."

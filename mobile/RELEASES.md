# Trux Companion — self-update (OTA) releases

Installed tablets check for a new version on every launch and offer to update —
no Play Store, no thumb drive. Here's how it's wired and how to ship an update.

## How it works
- The app reads `latest.json` from the **public** repo
  `github.com/turkyildiz/truxon-releases` at the stable path
  `releases/latest/download/latest.json` (always the newest release).
- `latest.json` = `{ versionCode, versionName, apkUrl, sha256, notes }`.
- If `versionCode` > the installed build number, the app downloads `apkUrl` and
  launches Android's installer. The driver taps **Update now → Install**.
- `sha256` is the hex SHA-256 of the APK (publish-release.sh fills it in). The
  app hashes the download and refuses to install on any mismatch — or if the
  field is missing — so a tampered or corrupted APK never reaches the
  installer.
- Only the APK + latest.json live in the public repo. Your source stays private.

## One-time setup (owner, ~3 min)
1. Authenticate the GitHub CLI (already installed at `~/dev-tools/gh`):
   ```bash
   ~/dev-tools/gh auth login
   ```
   Choose GitHub.com → HTTPS → login with a browser.
2. Create the public releases repo:
   ```bash
   ~/dev-tools/gh repo create turkyildiz/truxon-releases --public --add-readme
   ```
   (Public so tablets can download without any token. It holds only APKs.)

That's it. The app is already pointed at this repo.

## Shipping an update (every time)
From `mobile/`:
```bash
./publish-release.sh "Fixed X, added Y"
```
It bumps the build number, builds the release APK, and publishes a GitHub
release with the APK + latest.json. Within a launch or two, every tablet offers
the update.

Override the update source at build time if the repo name changes:
`--dart-define=UPDATE_URL=https://github.com/<owner>/<repo>/releases/latest/download/latest.json`

## First install is still manual (once)
You can't OTA your way onto a device that has nothing installed. Side-load the
current `app-release.apk` once (USB/thumb drive). Every update after that is
automatic.

## Migrating to a real keystore
Release builds now **fail** without `android/key.properties` — no more silent
debug-signed "releases". To set up real signing:

1. Generate a keystore (once, keep it forever — back it up somewhere safe):
   ```bash
   keytool -genkey -v -keystore ~/truxon-upload.jks \
     -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. Create `android/key.properties` (gitignored, never committed):
   ```properties
   storeFile=/home/<you>/truxon-upload.jks
   storePassword=<store password>
   keyAlias=upload
   keyPassword=<key password>
   ```
3. Build a release as usual — the build picks it up automatically.

**Operational caveat:** Android refuses updates signed with a different key.
Existing tablets running debug-signed builds **cannot OTA-update** to the first
real-keystore build — each one must be reinstalled manually once (uninstall,
then side-load the new APK). Every update after that is OTA again. And once the
fleet is on the real key, that keystore must never change.

## Notes
- The app needs **"Install unknown apps"** allowed for itself — Android prompts
  the first time an update installs; the driver taps Allow once.
- Debug builds check too, but install a debug-signed APK only over a debug one.
  Keep release signing consistent — see "Migrating to a real keystore" above.

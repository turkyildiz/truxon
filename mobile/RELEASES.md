# Trux Companion — self-update (OTA) releases

Installed tablets check for a new version on every launch and offer to update —
no Play Store, no thumb drive. Here's how it's wired and how to ship an update.

## How it works
- The app reads `latest.json` from the **public** repo
  `github.com/turkyildiz/truxon-releases` at the stable path
  `releases/latest/download/latest.json` (always the newest release).
- `latest.json` = `{ versionCode, versionName, apkUrl, sha256, rolloutPct, sig, notes }`.
- If `versionCode` > the installed build number, the app downloads `apkUrl` and
  launches Android's installer. The driver taps **Update now → Install**.
- `sha256` is the hex SHA-256 of the APK (publish-release.sh fills it in). The
  app hashes the download and refuses to install on any mismatch — or if the
  field is missing — so a tampered or corrupted APK never reaches the
  installer.
- `sig` is an **Ed25519 signature** over the security-critical fields
  (versionCode, versionName, apkUrl, sha256, rolloutPct), made with the owner's
  **offline** private key. The app carries the matching public key and refuses
  any manifest that isn't validly signed. This seals the gap sha256 alone can't:
  the checksum rides the same manifest, so a compromised release host could swap
  both — but it can't forge the signature. Downgrades and apkUrl redirects are
  signed against too.
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

## One-time setup: the OTA signing key (owner)
The app refuses any update manifest that isn't signed by your key, so you hold an
Ed25519 signing key. It was generated with:
```bash
openssl genpkey -algorithm ed25519 -out truxon-ota-signing.pem   # PRIVATE — store in KeePassXC
openssl pkey -in truxon-ota-signing.pem -pubout -outform DER | tail -c 32 | base64 -w0
```
The **public** key (32-byte, base64) is embedded in the app at
`lib/config.dart` → `AppConfig.otaSigningPublicKey`. The **private** key lives
only in your KeePassXC vault — never in the repo, never on a build box at rest.
To rotate it: generate a new pair, update the public key in `config.dart`, ship
that build to every tablet FIRST (old installs verify the old key), then start
signing with the new private key once they've updated.

## Shipping an update (every time)
From `mobile/`, with the signing key exported from the vault to a temp path:
```bash
export TRUX_OTA_SIGNING_KEY=/dev/shm/truxon-ota-signing.pem   # export from KeePassXC
./publish-release.sh "Fixed X, added Y"
shred -u /dev/shm/truxon-ota-signing.pem                       # remove the plaintext key
```
It bumps the build number, builds the release APK, **signs the manifest**, and
publishes a GitHub release with the APK + signed latest.json. Within a launch or
two, every tablet offers the update. The script aborts if `TRUX_OTA_SIGNING_KEY`
is unset — an unsigned manifest would be refused by every installed app, so it
refuses to publish one. Using `/dev/shm` keeps the plaintext key in RAM only.

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

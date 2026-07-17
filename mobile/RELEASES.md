# Trux Companion — self-update (OTA) releases

Installed tablets check for a new version on every launch and offer to update —
no Play Store, no thumb drive. Here's how it's wired and how to ship an update.

## How it works
- The app reads `latest.json` from the **public** repo
  `github.com/turkyildiz/truxon-releases` at the stable path
  `releases/latest/download/latest.json` (always the newest release).
- `latest.json` = `{ versionCode, versionName, apkUrl, notes }`.
- If `versionCode` > the installed build number, the app downloads `apkUrl` and
  launches Android's installer. The driver taps **Update now → Install**.
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

## Notes
- The app needs **"Install unknown apps"** allowed for itself — Android prompts
  the first time an update installs; the driver taps Allow once.
- Debug builds check too, but install a debug-signed APK only over a debug one.
  Keep release signing consistent (currently the debug key — set a real upload
  key before wide distribution so updates verify).

# Monday runbook — Truxon companion + fleet

Everything that needs **you** (deploys, devices, secrets) — in order. Code is
already written, committed, and (for the frontend) auto-deployed. This is the
"turn it all on" list.

Token/keys referenced here live in your password manager and earlier chat. Run
all `supabase` commands from `/home/turkyildiz/TRUXON`.

---

## A. Verify what auto-deployed over the weekend
1. Open **truxon.com** → sign in as Ike. Confirm **📍 Track & Trace** shows under
   Dashboard, the map loads, and Terrance's truck pin appears. Toggle **Weather
   radar** and **Severe alerts** (top-right of the page).
   - If the page is blank: Vercel → truxon project → Deployments → confirm the
     latest build (commit `Track & Trace …`) succeeded.

## B. Finish the DND alarm (blocked last week by the Supabase outage)
The push pipeline is built and half-verified (token registers; `notify` sends
200). We never saw it ring. **First redeploy `notify`** — over the weekend I
changed it to send urgent pushes **data-only**, so the app always renders the
full-screen DND alarm itself (the most likely fix), plus it now logs the FCM
result:
```bash
cd /home/turkyildiz/TRUXON && SUPABASE_ACCESS_TOKEN=… \
  ~/.local/bin/supabase functions deploy notify --project-ref okoeeyxxvzypjiumraxq
```
Also reinstall the latest APK (`~/Desktop/TruxCompanion-v1.apk`) — it has the
matching client-side alarm handling. Then, in order:
1. **On both tablets:** Settings → Apps → Trux Companion → **Notifications** →
   master toggle ON, and the **Dispatch alarms** channel ON + set to *Make sound*.
   (Android silently drops all pushes if notifications are off — prime suspect.)
2. Fire a test: truxon.com → Loads → assign any non-Terrance load **to Terrance**
   → Save. Watch the locked tablets.
3. If still silent, read the truth (logging is deployed): Supabase dashboard →
   Edge Functions → **notify → Logs**. Look for `notify.send begin` and
   `notify.fcm`:
   - `has_access_token: false` → the send key isn't minting in the function.
   - `ok:false, detail:…` → Firebase rejected it; the detail says why.
   - `ok:true` → Firebase accepted → it's a device-display issue (permissions/DND).
   Paste me whichever line appears and I'll finish the fix.
4. Install the **hardened alarm APK** I staged this weekend (see §E) — it makes
   the client side belt-and-suspenders and should remove the display-side doubt.

## C. OTA self-update — ✅ DONE (Sat 2026-07-18, verified live)
Repo `turkyildiz/truxon-releases` created; first release **v1.0.0+2**
published and verified end to end (manifest resolves, APK downloads 200,
valid 56.4MB APK). No more USB installs.
- **Every future update:** `cd mobile && ./publish-release.sh "what changed"`
  — bumps the build, builds the APK, publishes the release. Tablets offer it
  on next launch. (Details: `mobile/RELEASES.md`.)
- Note: any tablet still on the hand-installed Desktop APK (`+1`) will be
  offered `+2` automatically on next launch — a free live proof OTA works.
- A publish-time bug was found and fixed: the asset must be *named*
  `TruxCompanion.apk` (the `gh path#Label` syntax only sets a label, not the
  filename), else the download 404s. Fixed in `publish-release.sh`.

## D. Set a real release signing key (before all 14 trucks)
The APK is debug-signed today; OTA updates must keep one stable key or Android
rejects them. When ready, tell me and I'll wire a keystore + `build-apk.sh` in
one pass. Do this **before** wide rollout so the signing key never changes under
installed apps.

## E. Roll out to tablets
Use **`docs/tablet-provisioning.md`** (printable version was shared as an
artifact). Per tablet: Tailscale sign-in → Mumla → install Trux APK → log in as
the driver → **Location "Allow all the time"** + **Notifications on** → Samsung
**Never sleeping apps** → reboot test. Each driver uses their **own** login.

## F. Security hygiene (when convenient)
- Revoke the **Tailscale auth key** pasted in chat (Tailscale console → Settings → Keys).
- Rotate: admin password, Supabase/Vercel tokens, Anthropic key.
- Delete `~/Downloads/truxon-99a31-firebase-adminsdk-*.json` (it's stored as the notify secret now).
- Optional: restrict the Trux Azure app to only its mailbox (Exchange `New-ApplicationAccessPolicy`, see `docs/GO_LIVE.md`).

---

## What I did over the weekend (all committed; frontend live)
- **Track & Trace** map + **weather radar** + **severe-weather alerts** (live).
- **Track & Trace polish:** per-truck breadcrumb trail, click-to-center, stale-truck list.
- **Hardened alarm client** in the companion app (APK staged: `mobile/build/app/outputs/flutter-apk/app-release.apk`, also on your Desktop).
- This runbook.

## Still needs a decision from you
- Release signing key (§D) before fleet rollout.
- Whether to keep the old `turkyildiz@gmail.com` admin or retire it now.
- "There will be more" — drop the new asks here and I'll pick them up.

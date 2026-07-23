---
name: android-emulator
description: Headless Android emulator on the dev box for visually verifying the tablet app before publishing — boot, install, screenshot, iterate
metadata:
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

**Verify ALL tablet-app UI work on the emulator BEFORE publishing** (owner asked "cant you use android simulator?" 2026-07-21 — this is now the standard loop; never style blind again).

Setup that exists: `/dev/kvm` present; SDK at `~/sdk/android` with `emulator` package + `system-images;android-35;google_apis;x86_64`; AVD **truxtab** (Pixel Tablet, 2560x1600).

**New dev box (2026-07-23):** Ryzen AI 7 350, 16 threads, 28 GB RAM — owner upgraded specifically because emulation was slow. truxtab recreated here; cold headless boot in **29s** with `-memory 4096 -cores 4` (use these instead of the old `-memory 2048`). Old-box caveats (ANR dialogs, emulator dying under memory pressure) should no longer apply, but keep the wait-for-`sys.boot_completed` poll. Note: fresh AVD = wiped session → the authed walk needs the owner to log in driver2 once (rotated password is owner-only).

The loop:
1. Boot headless: `$ANDROID_HOME/emulator/emulator -avd truxtab -no-window -no-audio -gpu swiftshader_indirect -no-boot-anim -memory 2048` then `adb wait-for-device` + poll `sys.boot_completed`. Software GPU is SLOW — expect ANR dialogs (tap Wait) and give launches 20-25s. The emulator can die under memory pressure (14GB box); just re-boot it.
2. `./build-apk.sh release` + `adb install -r` (same signing key → session survives reinstalls).
3. Login driver2@aidalogistics.com. DENY location + notifications (keeps the fleet map clean — no fake GPS). adb typing: tap the field, `input keyevent 123` (cursor to end), delete-loop, `input text`, `keyevent 61` (tab) / `66` (enter); taps mid-flow miss when the keyboard shifts the layout. **Credential caveat (2026-07-23):** the rotated driver2 password lives ONLY with the owner (see [[security-posture]]) — on a fresh/wiped AVD the authed walk needs the owner to log in once (session then persists across same-key reinstalls). Do NOT rotate driver2 to get in: it signs out the real tablet #2.
4. Screenshot: `adb exec-out screencap -p > file.png`. Dark mode: `adb shell cmd uimode night yes`.
5. Kill when done: `adb emu kill` (drops the test presence from the fleet radio roster).

[[one-app-radio]] findings this workflow caught on day one: two permission-dialog crash paths (dismissing ANY dialog blanked the app — now best-effort everywhere + friendly retry screen) and the edge-to-edge tablet layout (now a centered 920dp column). Shipped as v1.0.0+10.

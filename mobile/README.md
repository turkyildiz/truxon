# Trux Companion (Flutter)

Android / iOS companion for Truxon TMS. Built for truck-mounted Samsung tablets
and dispatcher devices.

## Features

| # | Feature | Status | How |
|---|---------|--------|-----|
| 1 | **Driver login** (Truxon user/pass) | ✅ | Supabase Auth (`login_screen.dart`) |
| — | My loads · status · offline outbox · paperwork | ✅ | DTO RPCs (`api.dart`, `loads_screen.dart`) |
| 2 | **Trux voice assistant** — British, Jarvis-style | ✅ | On-device STT + en-GB TTS → `trux-agent` edge fn (`trux_voice.dart`, `voice_screen.dart`) |
| 3 | **Delivery-receipt photos** (POD/BOL/receipt…) | ✅ | Camera → Storage `load/<id>/…` → `driver_add_document` RPC (`loads_screen.dart`) |
| 4 | **Always-on background GPS** | ✅ | Foreground service, survives background + reboot (`tracking_service.dart`) |
| 5 | **Mumla PTT** to dispatchers | ✅ | `mumble://` deep-link to NAS over Tailscale (`mumble.dart`, `radio_screen.dart`) |
| 6 | **DND-bypass alarms** for urgent dispatch | ✅ | Alarm-stream channel + full-screen intent + FCM `urgent` (`alarms.dart`, `push.dart`) |

Drivers see **Loads / Trux / Radio / About**. Office roles (dispatcher, admin,
accountant, maintenance) see **Trux / Radio / About** — the voice agent scoped to
their permissions, plus the radio.

## Prerequisites (backend)

1. Apply migrations (in order):
   - `supabase/migrations/20260717010001_companion_driver_gps_push.sql` (Phase 1)
   - `supabase/migrations/20260717200001_driver_pod_upload.sql` (**new** — driver
     storage access + POD upload). Without this, drivers can't read paperwork or
     upload receipts.
   ```bash
   SUPABASE_ACCESS_TOKEN=… ~/.local/bin/supabase db push
   ```
2. Redeploy edge functions: `trux-agent`, `notify` (notify gained the `urgent`
   flag), plus `admin-users`, `extract-pdf` as usual.
   ```bash
   SUPABASE_ACCESS_TOKEN=… ~/.local/bin/supabase functions deploy notify --project-ref okoeeyxxvzypjiumraxq
   ```
3. Link each driver row to a login (`Drivers` → **Linked login**).

## Build / run

```bash
cd mobile
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=https://okoeeyxxvzypjiumraxq.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your_anon_key
```

Optional build-time overrides (`--dart-define=`):

| Define | Default | Purpose |
|--------|---------|---------|
| `TRUX_VOICE_LOCALE` | `en-GB` | TTS voice locale (Jarvis = British) |
| `MUMBLE_HOST` | `100.89.140.98` | NAS tailnet IP of the Murmur server |
| `MUMBLE_PORT` | `64738` | Mumble port |

Release APK for side-loading onto tablets:
```bash
flutter build apk --release \
  --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…
```

## Feature notes

### 2 — Trux voice (British)
`TruxVoiceController` uses `speech_to_text` for on-device recognition and
`flutter_tts` set to `en-GB` (it auto-selects a male GB voice when the TTS engine
exposes one — install *Google Speech Services* / a UK voice on the tablet for the
best Jarvis timbre). Recognised text is sent to the **same** `trux-agent` brain as
the web chat, so answers and any write-actions stay scoped to the caller's role
and RLS. Write actions come back as confirm cards (tap Confirm, or say it in
hands-free mode). No audio or LLM keys leave the device.

### 3 — Receipt photos
Photos upload to the `documents` bucket under `load/<load_id>/…` — the only path
the driver storage policy and `driver_add_document` RPC permit — then a metadata
row is registered and an `activity_log` entry (`pod_uploaded`) gives dispatch
visibility on the web load page.

### 4 — Always-on tracking
A `flutter_foreground_task` foreground service keeps a dedicated isolate alive
when the app is backgrounded/screen-off and **auto-restarts after reboot**. It
samples GPS every 60 s, durably queues fixes in `SharedPreferences`, and flushes
to `ingest_vehicle_positions`. The UI isolate owns the Supabase session and hands
the current access token to the tracker via `SessionStore`; if the token is
briefly stale the tracker keeps sampling and uploads catch up — **no fixes are
lost**. Tracking turns on when the driver goes On Duty *or* has an active load,
and shows a persistent "sharing location" notification (required by Android).

For Samsung specifically: add the app to **Never sleeping apps** (Settings →
Battery → Background usage limits) so One UI doesn't doze the service. Kiosk/Knox
can pin the app.

### 5 — Radio (Mumla)
The Radio tab deep-links `mumble://<name>@100.89.140.98:64738/` into Mumla
(install prompt if missing). Reachable because the tablet is on the Tailscale
tailnet (install the **Tailscale** app + sign in first). In Mumla, map
Push-to-Talk to a big on-screen button.

### 6 — DND-bypass alarms
The `dispatch_alarm` channel plays on the **alarm** audio stream and posts a
full-screen, alarm-category notification, so urgent dispatch pushes ring even in
silent/Do-Not-Disturb and wake the screen. New load **assignments** default to
urgent (`notify` sets `urgent:true`); dispatch can also send
`{action:"send", user_id, urgent:true, …}`. If a driver has muted even alarms
under a custom DND schedule, `Alarms.openDndAccessSettings()` opens the exemption
screen. Local `Alarms.scheduleAlarm(...)` can also fire appointment alarms.

**Urgent push requires Firebase** (below). Local alarms and everything else work
without it.

## Firebase (push) — optional, enables urgent alarms

1. Create a Firebase project; add an Android app with id `com.truxon.truxon_companion`.
2. Download `google-services.json` → `mobile/android/app/google-services.json`.
3. Uncomment `id("com.google.gms.google-services")` in
   `android/app/build.gradle.kts`, and add the plugin in the project-level Gradle
   (`android/settings.gradle.kts` plugins block:
   `id("com.google.gms.google-services") version "4.4.2" apply false`).
4. Put the Firebase **service account JSON** on the `notify` edge function as
   `FCM_SERVICE_ACCOUNT_JSON` (already the notify contract). iOS additionally
   needs the APNs key secrets.

Without these steps `PushService.init` no-ops and the app runs normally.

## Store release

Apple Developer + Google Play accounts required. Background location needs the
"Always" permission rationale + privacy labels; Google Play requires a
prominent-disclosure + a permissions-declaration form for background location and
full-screen-intent/exact-alarm usage.

## Phase 2 (later)
Auto-provision Mumble accounts from Truxon; paystubs; QuickBooks payroll sync.

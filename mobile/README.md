# Trux Companion (Flutter)

Android / iOS companion for Truxon TMS: driver loads, status updates, paperwork, GPS (60s), and push registration.

## Prerequisites

1. Apply migration `supabase/migrations/20260717010001_companion_driver_gps_push.sql` (`supabase db push`).
2. Deploy edge functions: `admin-users`, `notify`.
3. Link each driver row to a login (`Drivers` → **Linked login**, or create user with `link_driver_id`).
4. Optional push: set `FCM_SERVICE_ACCOUNT_JSON` (and APNs secrets) on the `notify` function.

## Run

```bash
cd mobile
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your_anon_key
```

## Features (Phase 1)

| Feature | Status |
|---------|--------|
| Auth (Supabase) | Yes |
| My loads (DTO RPC, no rate) | Yes |
| Status: assigned → in_transit → delivered | Yes |
| Offline status outbox | Yes |
| On-duty toggle + GPS every 60s | Yes |
| Paperwork list + signed URL | Yes |
| Push token registration API | Client helper ready; wire FCM plugin for production |
| Trux voice agent | Phase 2 |
| Mumble PTT | Phase 3 |

## Store release

Apple Developer + Google Play accounts required. Background location needs Always permission copy and privacy labels.

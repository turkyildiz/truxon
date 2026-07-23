# Truxon Dev Box (this machine)

> Re-provisioned 2026-07-23 on new hardware (Ryzen AI 7 350, 16 threads, 28 GB RAM) — old box was too slow for Android emulation. Username is now `ike`; repo lives at `/home/ike/TRUXON` with `~/src/truxon` symlinked to it, so the paths below still work.

## Locations
- Repo: `~/src/truxon` (symlink → `/home/ike/TRUXON`)
- Flutter: `~/sdk/flutter`
- Android SDK: `~/sdk/android` (platforms 35+36, emulator, AVD `truxtab`)
- Java: `~/sdk/jdk17` (Temurin, JAVA_HOME in ~/.bashrc)
- Supabase CLI: `~/.local/bin/supabase`
- Deno: `~/.deno/bin/deno`
- Node (nvm): Node 24 LTS

## Daily workflow

```bash
# load toolchain (already in ~/.bashrc)
source ~/.bashrc

cd ~/src/truxon

# Local Supabase (Docker) — start if not running
supabase start
supabase status          # Studio http://127.0.0.1:54323

# Frontend
cd frontend
# .env.local already points at local Supabase
npm run dev              # http://localhost:5173

# Schema change
# add supabase/migrations/YYYYMMDDHHMMSS_name.sql
supabase db reset        # local only — re-applies all migrations

# Edge functions (local)
supabase functions serve

# Mobile companion
cd mobile
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=http://10.0.2.2:54321 \
  --dart-define=SUPABASE_ANON_KEY="$(grep ANON_KEY ~/.config/truxon/local-supabase.env | cut -d= -f2- | tr -d '"')"
# (10.0.2.2 is the Android emulator host loopback)
```

## Remote (prod) Supabase
```bash
supabase login
supabase link --project-ref <REF>
supabase db push
supabase functions deploy extract-pdf distance admin-users notify trux-agent trux-inbox watchdog fuel-import toll-sync
```

## Notes
- Docker: you are in the `docker` group; if `docker ps` fails after reboot, log out/in once.
- Local default DB password is `postgres` (see `supabase status`).
- Public signup is disabled; create users via Studio Auth or admin-users function.

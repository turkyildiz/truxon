#!/usr/bin/env bash
# Build the Trux Companion APK. Usage:
#   ./build-apk.sh                 # release APK (installable, side-load)
#   ./build-apk.sh debug           # debug APK
#   ./build-apk.sh run             # install + live logs on a plugged-in tablet
#
# The Supabase publishable/anon key is public-safe (RLS enforces access), so it
# lives here for convenience. Override by exporting SUPABASE_ANON_KEY first.
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://okoeeyxxvzypjiumraxq.supabase.co}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-sb_publishable_Ak8T-1XgtjC00LXbiI9xDA_o5b_n7C-}"

DEFINES=(--dart-define=SUPABASE_URL="$SUPABASE_URL"
         --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY")

cd "$(dirname "$0")"
case "${1:-release}" in
  run)     flutter run "${DEFINES[@]}" ;;
  debug)   flutter build apk --debug "${DEFINES[@]}" ;;
  release) flutter build apk --release "${DEFINES[@]}" ;;
  *) echo "unknown mode: $1 (use: release | debug | run)"; exit 1 ;;
esac

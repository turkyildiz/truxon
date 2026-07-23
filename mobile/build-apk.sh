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
# Valhalla truck routing on the NAS via Tailscale Funnel (deploy/valhalla/).
# Public endpoint; the app falls back to the bearing line while it's unreachable.
VALHALLA_URL="${VALHALLA_URL:-https://aida-nas.tail2c5ca.ts.net}"

DEFINES=(--dart-define=SUPABASE_URL="$SUPABASE_URL"
         --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
         --dart-define=VALHALLA_URL="$VALHALLA_URL")

cd "$(dirname "$0")"
case "${1:-release}" in
  run)     flutter run "${DEFINES[@]}" ;;
  debug)   flutter build apk --debug "${DEFINES[@]}" ;;
  # Fleet phones are all arm64. sherpa-onnx (offline voice) ships ~25 MB of
  # native libs per ABI — a universal release APK hit 170 MB. --split-per-abi
  # is the only mechanism the Flutter gradle plugin honors for stripping
  # plugin-AAR jniLibs (ndk.abiFilters gets ignored); it emits
  # app-arm64-v8a-release.apk, normalized here to app-release.apk so the
  # OTA publish path stays unchanged. Debug builds remain universal so the
  # x86_64 emulator can run the app.
  release)
    flutter build apk --release --split-per-abi --target-platform android-arm64 "${DEFINES[@]}"
    cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
       build/app/outputs/flutter-apk/app-release.apk
    ;;
  *) echo "unknown mode: $1 (use: release | debug | run)"; exit 1 ;;
esac

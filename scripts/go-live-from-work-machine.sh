#!/usr/bin/env bash
# Run this ON THE WORK MACHINE (where Supabase CLI is logged in or tokens live).
# Usage:
#   ./scripts/go-live-from-work-machine.sh
#   ./scripts/go-live-from-work-machine.sh /path/to/env
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# Load first available env file
CANDIDATES=(
  "${1:-}"
  "$HOME/truckson-live.env"
  "$HOME/TRUXON/frontend/.env.local"
  "/home/turkyildiz/TRUXON/frontend/.env.local"
  "$ROOT/frontend/.env.local"
  "$HOME/.config/truxon/live.env"
)
ENV_FILE=""
for f in "${CANDIDATES[@]}"; do
  [[ -n "$f" && -f "$f" ]] && ENV_FILE="$f" && break
done

if [[ -n "$ENV_FILE" ]]; then
  yellow "Loading $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  # support KEY=val and export KEY=val
  # shellcheck disable=SC1091
  source <(sed -E 's/^[[:space:]]*export[[:space:]]+//; /^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^([[:alnum:]_]+)=(.*)$/export \1=\2/' "$ENV_FILE")
  set +a
fi

# Map Vite/Next names → Supabase CLI names
export SUPABASE_URL="${SUPABASE_URL:-${VITE_SUPABASE_URL:-${NEXT_PUBLIC_SUPABASE_URL:-}}}"
if [[ -z "${SUPABASE_PROJECT_REF:-}" && -n "${SUPABASE_URL:-}" ]]; then
  SUPABASE_PROJECT_REF="$(echo "$SUPABASE_URL" | sed -E 's#https://([a-z0-9]+)\.supabase\.co.*#\1#')"
  export SUPABASE_PROJECT_REF
fi
export SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-${SUPABASE_SECRET_KEY:-}}"

# Prefer existing CLI login; else require SUPABASE_ACCESS_TOKEN
if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  if supabase projects list >/dev/null 2>&1; then
    yellow "Using existing supabase CLI login session"
  else
    red "No SUPABASE_ACCESS_TOKEN and CLI not logged in."
    red "On this machine run:  supabase login"
    red "Or export SUPABASE_ACCESS_TOKEN=sbp_... then re-run."
    exit 1
  fi
fi

if [[ -z "${SUPABASE_PROJECT_REF:-}" ]]; then
  export SUPABASE_PROJECT_REF=okoeeyxxvzypjiumraxq
  yellow "Defaulting project ref to $SUPABASE_PROJECT_REF"
fi

exec "$ROOT/scripts/go-live.sh"

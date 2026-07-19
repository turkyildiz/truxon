#!/usr/bin/env bash
# Truxon go-live: push migrations + deploy edge functions.
#
# Prerequisites (export before running, or put in a chmod 600 env file):
#   SUPABASE_ACCESS_TOKEN   # https://supabase.com/dashboard/account/tokens
#   SUPABASE_PROJECT_REF    # Project Settings → General → Reference ID
#   Optional secrets:
#     XAI_API_KEY / LLM_API_KEY / LLM_BASE_URL / LLM_MODEL
#     GOOGLE_MAPS_API_KEY
#     FCM_SERVICE_ACCOUNT_JSON   # raw JSON string
#     NOTIFY_WEBHOOK_SECRET
#
# Usage:
#   ./scripts/go-live.sh
#   ./scripts/go-live.sh /path/to/truckson-live.env
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -n "${1:-}" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$1"; set +a
fi

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

need() {
  if [[ -z "${!1:-}" ]]; then
    red "Missing env: $1"
    exit 1
  fi
}

if ! command -v supabase >/dev/null 2>&1; then
  red "supabase CLI not in PATH. Install: https://supabase.com/docs/guides/cli"
  exit 1
fi

need SUPABASE_ACCESS_TOKEN
need SUPABASE_PROJECT_REF

export SUPABASE_ACCESS_TOKEN

yellow "Linking project $SUPABASE_PROJECT_REF…"
supabase link --project-ref "$SUPABASE_PROJECT_REF"

yellow "Pushing migrations…"
supabase db push

yellow "Deploying edge functions…"
supabase functions deploy extract-pdf distance admin-users notify trux-agent trux-inbox watchdog fuel-import toll-sync

# Secrets (only set if provided — never clear existing)
SECRETS=()
[[ -n "${LLM_API_KEY:-${XAI_API_KEY:-}}" ]] && SECRETS+=( "LLM_API_KEY=${LLM_API_KEY:-$XAI_API_KEY}" )
[[ -n "${LLM_BASE_URL:-}" ]] && SECRETS+=( "LLM_BASE_URL=$LLM_BASE_URL" )
[[ -n "${LLM_MODEL:-}" ]] && SECRETS+=( "LLM_MODEL=$LLM_MODEL" )
[[ -n "${XAI_API_KEY:-}" ]] && SECRETS+=( "XAI_API_KEY=$XAI_API_KEY" )
[[ -n "${OPENAI_API_KEY:-}" ]] && SECRETS+=( "OPENAI_API_KEY=$OPENAI_API_KEY" )
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && SECRETS+=( "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" )
[[ -n "${GOOGLE_MAPS_API_KEY:-}" ]] && SECRETS+=( "GOOGLE_MAPS_API_KEY=$GOOGLE_MAPS_API_KEY" )
[[ -n "${FCM_SERVICE_ACCOUNT_JSON:-}" ]] && SECRETS+=( "FCM_SERVICE_ACCOUNT_JSON=$FCM_SERVICE_ACCOUNT_JSON" )
[[ -n "${NOTIFY_WEBHOOK_SECRET:-}" ]] && SECRETS+=( "NOTIFY_WEBHOOK_SECRET=$NOTIFY_WEBHOOK_SECRET" )

if ((${#SECRETS[@]})); then
  yellow "Setting ${#SECRETS[@]} function secrets…"
  supabase secrets set "${SECRETS[@]}"
else
  yellow "No optional secrets provided (LLM / Maps / FCM) — skipped."
fi

green "Go-live DB + functions complete."
echo ""
echo "Frontend: Vercel auto-deploys from main (set VITE_SUPABASE_* in Vercel if missing)."
echo "Optional Maps JS: VITE_GOOGLE_MAPS_JS_KEY on Vercel (browser key, referrer-restricted)."
echo ""
echo "Companion app:"
echo "  cd mobile && flutter run \\"
echo "    --dart-define=SUPABASE_URL=https://${SUPABASE_PROJECT_REF}.supabase.co \\"
echo "    --dart-define=SUPABASE_ANON_KEY=\$ANON_KEY"
echo ""
echo "Manual checks:"
echo "  1) Admin web login"
echo "  2) Drivers → link login"
echo "  3) Companion: duty + GPS pin on Dispatch"
echo "  4) Dispatch Trux chat (if agent secrets set)"

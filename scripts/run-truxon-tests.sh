#!/usr/bin/env bash
# Truxon TMS test harness — smoke + optional static security + optional SQL.
# Usage:
#   ./scripts/run-truxon-tests.sh              # smoke + static-security
#   ./scripts/run-truxon-tests.sh smoke
#   ./scripts/run-truxon-tests.sh static-security
#   ./scripts/run-truxon-tests.sh sql          # requires DATABASE_URL or local supabase
#   ./scripts/run-truxon-tests.sh all
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SCOPE="${1:-default}"
FAIL=0

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }

# Prefer ripgrep; fall back to grep -R so the harness works on stock macOS.
if command -v rg >/dev/null 2>&1; then
  search() { rg -n -- "$1" "${@:2}"; }
  search_q() { rg -n -- "$1" "${@:2}" >/dev/null 2>&1; }
else
  search() { grep -RInE -- "$1" "${@:2}" 2>/dev/null; }
  search_q() { grep -RInE -- "$1" "${@:2}" >/dev/null 2>&1; }
fi

need_repo() {
  if [[ ! -f frontend/package.json || ! -d supabase/migrations ]]; then
    red "Not a Truxon repo root (need frontend/ + supabase/migrations/). cwd=$ROOT"
    exit 2
  fi
}

run_smoke() {
  hdr "A — Smoke (frontend build)"
  if [[ ! -d frontend/node_modules ]]; then
    yellow "Installing frontend deps…"
    (cd frontend && npm ci)
  fi
  if (cd frontend && npm run build); then
    green "PASS A1 frontend build"
  else
    red "FAIL A1 frontend build"
    FAIL=1
  fi

  local n
  n=$(find supabase/migrations -name '*.sql' | wc -l | tr -d ' ')
  if [[ "$n" -ge 1 ]]; then
    green "PASS A2 migrations present ($n files)"
  else
    red "FAIL A2 no migrations"
    FAIL=1
  fi

  for f in supabase/functions/admin-users/index.ts \
           supabase/functions/extract-pdf/index.ts \
           supabase/functions/distance/index.ts \
           supabase/functions/_shared/auth.ts; do
    if [[ -f "$f" ]]; then
      green "PASS A3 $f"
    else
      red "FAIL A3 missing $f"
      FAIL=1
    fi
  done
}

# Extract function body-ish window: from CREATE to next CREATE or EOF
func_window() {
  local name="$1"
  # shellcheck disable=SC2016
  awk -v n="$name" '
    BEGIN { IGNORECASE=1 }
    $0 ~ "function public\\." n "\\(" || $0 ~ "function public\\." n " " { p=1 }
    p { print }
    p && NR>1 && /^create or replace function/ && $0 !~ n { exit }
  ' supabase/migrations/*.sql 2>/dev/null || true
}

run_static_security() {
  hdr "B — Static security review (source-level)"

  # Prefer latest definition: later migrations CREATE OR REPLACE earlier ones.
  # Pass if any definition body (esp. Phase 0+) references my_role().
  if grep -RInE "function public\.dashboard_summary" -A 40 supabase/migrations 2>/dev/null | grep -qE 'my_role\s*\('; then
    green "PASS B1 dashboard_summary references my_role()"
  elif grep -RInE "function public\.dashboard_summary" supabase/migrations >/dev/null 2>&1; then
    red "FAIL B1 dashboard_summary only checks auth.uid() — role leak risk"
    FAIL=1
  else
    yellow "UNVERIFIED B1 dashboard_summary not found in migrations"
  fi

  if grep -RInE "function public\.global_search" -A 25 supabase/migrations 2>/dev/null | grep -qE 'my_role\s*\('; then
    green "PASS B2 global_search references my_role()"
  elif grep -RInE "function public\.global_search" supabase/migrations >/dev/null 2>&1; then
    red "FAIL B2 global_search only checks auth.uid() — role leak risk"
    FAIL=1
  else
    yellow "UNVERIFIED B2 global_search not found"
  fi

  # B6: storage read policies should role-gate (later migrations CREATE/DROP policies)
  # Pass if any documents bucket SELECT policy includes my_role (Phase 0 fix).
  if grep -RInE "bucket_id = 'documents'" supabase/migrations >/dev/null 2>&1; then
    if grep -RInE -A8 "documents_bucket_read|bucket_id = 'documents'" supabase/migrations 2>/dev/null | grep -qE 'my_role\s*\('; then
      # Also ensure Phase 0 (or equivalent) redefines SELECT with role gate, not only delete.
      if grep -RInE "for select to authenticated" -A6 supabase/migrations 2>/dev/null | grep -B2 -A6 "bucket_id = 'documents'" | grep -qE 'my_role\s*\('; then
        green "PASS B6 storage documents SELECT role-gated with my_role()"
      else
        # Fallback: phase0 file explicitly documents_bucket_read + my_role
        if grep -RInE "documents_bucket_read" -A8 supabase/migrations 2>/dev/null | grep -qE 'my_role\s*\('; then
          green "PASS B6 storage documents_bucket_read role-gated"
        else
          red "FAIL B6 storage documents SELECT open to all authenticated"
          FAIL=1
        fi
      fi
    else
      red "FAIL B6 storage documents policies lack my_role()"
      FAIL=1
    fi
  else
    yellow "SKIP B6 no documents bucket policies found"
  fi

  # B11: filter injection — look for .or(`...${q}
  if grep -nE '\.or\(`[^`]*\$\{q\}' frontend/src/data.ts >/dev/null 2>&1 \
     || grep -nE '\.or\(`[^`]*\$\{filters\.q\}' frontend/src/data.ts >/dev/null 2>&1; then
    red "FAIL B11 data.ts interpolates search text into .or() filter — injection risk"
    FAIL=1
  else
    green "PASS B11 no raw \${q} inside .or() in data.ts"
  fi

  # C6: void_invoice paid guard (check all migrations; Phase 0 redefines)
  if grep -RInE "function public\.void_invoice|Cannot void a paid" -A 40 supabase/migrations 2>/dev/null | grep -qiE "Cannot void a paid|status = 'paid'"; then
    green "PASS C6 void_invoice rejects paid invoices"
  elif grep -RInE "function public\.void_invoice" supabase/migrations >/dev/null 2>&1; then
    red "FAIL C6 void_invoice has no paid-status guard in source"
    FAIL=1
  else
    yellow "UNVERIFIED C6 void_invoice not found"
  fi

  # C1: status change only via RPC
  if search_q "change_load_status" supabase/migrations \
     && search_q "loads_before_update|status is distinct from" supabase/migrations; then
    green "PASS C1 workflow lock helpers present (change_load_status + before update)"
  else
    yellow "UNVERIFIED C1 status lock markers not found"
  fi

  # C7: numbering advisory lock or sequence
  if grep -RInE "function public\.next_load_number|pg_advisory_xact_lock" -A 20 supabase/migrations 2>/dev/null | grep -qE 'pg_advisory_xact_lock|nextval'; then
    green "PASS C7 next_load_number uses advisory lock or sequence"
  elif grep -RInE "function public\.next_load_number" supabase/migrations >/dev/null 2>&1; then
    red "FAIL C7 next_load_number has no concurrency lock"
    FAIL=1
  else
    yellow "UNVERIFIED C7 next_load_number not found"
  fi

  # C8: double-booking guard
  if search_q "assert_no_double_booking|already assigned to another active load" supabase/migrations; then
    green "PASS C8 double-booking guard present"
  else
    red "FAIL C8 no double-booking guard in migrations"
    FAIL=1
  fi

  # D1: driver_load_dto must not be granted to authenticated
  if search_q "driver_load_dto" supabase/migrations; then
    if grep -RInE "grant execute on function public\.driver_load_dto" supabase/migrations 2>/dev/null | grep -qi authenticated; then
      red "FAIL D1 driver_load_dto must not GRANT EXECUTE to authenticated"
      FAIL=1
    else
      green "PASS D1 driver_load_dto has no authenticated grant"
    fi
  else
    yellow "SKIP D1 driver_load_dto not present yet"
  fi
}

run_sql() {
  hdr "C — SQL tests"
  local url="${DATABASE_URL:-${SUPABASE_DB_URL:-}}"
  if [[ -z "$url" ]] && command -v supabase >/dev/null 2>&1; then
    url="$(supabase status -o env 2>/dev/null | sed -n 's/^DB_URL=//p' | tr -d '"' || true)"
  fi
  if [[ -z "$url" ]]; then
    yellow "SKIP SQL — set DATABASE_URL or run supabase start"
    return 0
  fi
  local f="supabase/tests/rls_and_workflow.sql"
  if [[ ! -f "$f" ]]; then
    red "FAIL missing $f — run /truxon-test scaffold"
    FAIL=1
    return 0
  fi
  if command -v psql >/dev/null 2>&1; then
    if psql "$url" -v ON_ERROR_STOP=1 -f "$f"; then
      green "PASS SQL file executed"
    else
      red "FAIL SQL tests"
      FAIL=1
    fi
  else
    yellow "SKIP SQL — psql not installed"
  fi
}

need_repo

case "$SCOPE" in
  smoke) run_smoke ;;
  static-security|security) run_static_security ;;
  sql|workflow) run_sql ;;
  all)
    run_smoke
    run_static_security
    run_sql
    ;;
  default)
    run_smoke
    run_static_security
    ;;
  *)
    echo "Unknown scope: $SCOPE (smoke|static-security|sql|all)"
    exit 2
    ;;
esac

hdr "Summary"
if [[ "$FAIL" -eq 0 ]]; then
  green "All executed checks passed (skipped items may remain)."
  exit 0
else
  red "One or more checks FAILED."
  exit 1
fi

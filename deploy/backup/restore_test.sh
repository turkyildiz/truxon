#!/usr/bin/env bash
# Weekly automated restore verification (the "0 errors" in 3-2-1-1-0).
# Restores the newest encrypted Supabase dump into a throwaway Postgres
# container and ASSERTS the outcome: core tables must contain rows, and if
# the restored data says documents exist, the storage schema's object
# metadata must be there too. pg_restore's harmless role/extension noise is
# tolerated but shown — a dump that restores zero rows FAILS loudly instead
# of printing PASS.
#
# Env: BACKUP_PASSPHRASE
# Usage:  ./restore_test.sh [backup_dir]
set -euo pipefail

BACKUP_DIR="${1:-/volume1/backups/truxon}"
LATEST="$(ls -1t "$BACKUP_DIR"/db_*.dump.gpg 2>/dev/null | head -1)"

if [[ -z "$LATEST" ]]; then
  echo "FAIL: no database backups found in $BACKUP_DIR" >&2
  exit 1
fi
echo "Testing restore of: $LATEST"

CONTAINER="truxon-restore-test-$$"
# postgres:17 to match the Supabase server — a version mismatch here makes
# pg_restore reject the dump (and older pg_dump silently produced empty dumps).
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=restore_test postgres:17-alpine >/dev/null
RESTORE_LOG="$(mktemp)"
trap 'docker rm -f "$CONTAINER" >/dev/null; rm -f "$RESTORE_LOG"' EXIT

echo "Waiting for temporary Postgres…"
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -U postgres -q && break
  sleep 1
done

# Supabase dumps reference roles/extensions/auth-schema FKs that don't exist
# locally; --no-owner/--no-privileges plus continuing past those errors is
# expected — the row-count assertions below are what decides pass/fail.
# The passphrase goes over fd 3, never the command line (visible in `ps`).
gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --decrypt "$LATEST" 3<<<"$BACKUP_PASSPHRASE" \
  | docker exec -i "$CONTAINER" pg_restore -U postgres -d restore_test \
      --no-owner --no-privileges 2>"$RESTORE_LOG" || true

if [[ -s "$RESTORE_LOG" ]]; then
  echo "pg_restore stderr ($(grep -c 'error' "$RESTORE_LOG" || true) error lines — role/extension/FK noise is expected):"
  tail -5 "$RESTORE_LOG"
fi

count() {
  docker exec "$CONTAINER" psql -U postgres -d restore_test -tAc \
    "SELECT coalesce((SELECT count(*) FROM $1), -1)" 2>/dev/null || echo "-1"
}

PROFILES="$(count public.profiles)"
LOADS="$(count public.loads)"
CUSTOMERS="$(count public.customers)"
DOCS="$(count public.documents)"
OBJECTS="$(count storage.objects)"

echo "Restored counts: $PROFILES profiles, $LOADS loads, $CUSTOMERS customers, $DOCS document rows, $OBJECTS storage objects"

FAIL=0
for check in "profiles:$PROFILES" "loads:$LOADS" "customers:$CUSTOMERS"; do
  if [[ "${check#*:}" -lt 1 ]]; then
    echo "FAIL: table ${check%:*} restored with ${check#*:} rows (expected > 0)" >&2
    FAIL=1
  fi
done
# The dump includes --schema=storage; if the business data references
# documents, the storage object metadata must have survived the round trip.
if [[ "$DOCS" -gt 0 && "$OBJECTS" -lt 1 ]]; then
  echo "FAIL: public.documents has $DOCS rows but storage.objects restored $OBJECTS — storage schema lost" >&2
  FAIL=1
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL: restore test did NOT verify — treat the newest backup as suspect" >&2
  exit 1
fi
echo "PASS: restore verified — $PROFILES profiles, $LOADS loads, $CUSTOMERS customers, $DOCS documents / $OBJECTS storage objects"

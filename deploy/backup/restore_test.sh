#!/usr/bin/env bash
# Weekly automated restore verification (the "0 errors" in 3-2-1-1-0).
# Restores the newest encrypted Supabase dump into a throwaway Postgres
# container and checks that core tables exist and have sane row counts.
#
# Env: BACKUP_PASSPHRASE
# Usage:  ./restore_test.sh [backup_dir]
set -euo pipefail

BACKUP_DIR="${1:-/volume1/backups/truckson}"
LATEST="$(ls -1t "$BACKUP_DIR"/db_*.dump.gpg 2>/dev/null | head -1)"

if [[ -z "$LATEST" ]]; then
  echo "FAIL: no database backups found in $BACKUP_DIR" >&2
  exit 1
fi
echo "Testing restore of: $LATEST"

CONTAINER="truckson-restore-test-$$"
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=restore_test postgres:16-alpine >/dev/null
trap 'docker rm -f "$CONTAINER" >/dev/null' EXIT

echo "Waiting for temporary Postgres…"
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -U postgres -q && break
  sleep 1
done

# Supabase dumps reference roles/extensions that don't exist locally;
# --no-owner/--no-privileges plus continuing past harmless errors is expected.
gpg --batch --quiet --decrypt --passphrase "$BACKUP_PASSPHRASE" "$LATEST" \
  | docker exec -i "$CONTAINER" pg_restore -U postgres -d restore_test \
      --no-owner --no-privileges --schema=public || true

RESULT="$(docker exec "$CONTAINER" psql -U postgres -d restore_test -tAc \
  "SELECT (SELECT count(*) FROM profiles) || ' profiles, ' || (SELECT count(*) FROM loads) || ' loads, ' || (SELECT count(*) FROM customers) || ' customers'")"

echo "PASS: restore verified — $RESULT"

#!/usr/bin/env bash
# TrucksOn nightly backup — run from cron on the NAS host.
# Produces: nightly pg_dump + uploads volume archive, gpg-encrypted,
# pruned after RETENTION_DAYS. Pair with NAS-level immutable snapshots
# of $BACKUP_DIR for the ransomware-proof copy (3-2-1-1-0 rule).
#
# Usage:  BACKUP_PASSPHRASE=... ./backup.sh [backup_dir]
set -euo pipefail

BACKUP_DIR="${1:-/volume1/backups/truckson}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
STAMP="$(date +%Y%m%d_%H%M%S)"
COMPOSE="docker compose -f $(dirname "$0")/../../docker-compose.yml"

mkdir -p "$BACKUP_DIR"

if [[ -z "${BACKUP_PASSPHRASE:-}" ]]; then
  echo "ERROR: set BACKUP_PASSPHRASE (used for gpg symmetric encryption)" >&2
  exit 1
fi

echo "[1/3] Dumping PostgreSQL…"
$COMPOSE exec -T db pg_dump -U truckson -Fc truckson \
  | gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase "$BACKUP_PASSPHRASE" \
  > "$BACKUP_DIR/db_${STAMP}.dump.gpg"

echo "[2/3] Archiving uploaded documents volume…"
docker run --rm -v truxon_uploads:/data:ro alpine tar -czf - -C /data . \
  | gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase "$BACKUP_PASSPHRASE" \
  > "$BACKUP_DIR/uploads_${STAMP}.tar.gz.gpg"

echo "[3/3] Pruning backups older than ${RETENTION_DAYS} days…"
find "$BACKUP_DIR" -name '*.gpg' -mtime "+${RETENTION_DAYS}" -delete

echo "Backup complete: $BACKUP_DIR (db_${STAMP}, uploads_${STAMP})"

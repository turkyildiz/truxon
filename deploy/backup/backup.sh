#!/usr/bin/env bash
# Truxon nightly backup — runs on the UGREEN NAS, pulling FROM Supabase.
# Produces encrypted database dumps + document-storage archives, pruned
# after RETENTION_DAYS. Pair with NAS-level immutable snapshots of
# $BACKUP_DIR for the ransomware-proof copy (3-2-1-1-0 rule: Supabase's
# own backups + these local copies + immutable snapshot + restore test).
#
# The gpg passphrase travels over fd 3, never argv (argv is visible in `ps`
# to every process on the NAS).
#
# Required environment (put in /etc/truxon-backup.env, chmod 600):
#   SUPABASE_DB_URL      postgresql://postgres:...@db.<ref>.supabase.co:5432/postgres
#   SUPABASE_URL         https://<ref>.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY  (Storage read access)
#   BACKUP_PASSPHRASE    gpg symmetric encryption passphrase
#
# Usage:  ./backup.sh [backup_dir]
set -euo pipefail

BACKUP_DIR="${1:-/volume1/backups/truxon}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
STAMP="$(date +%Y%m%d_%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${SUPABASE_DB_URL:?set SUPABASE_DB_URL}"
: "${BACKUP_PASSPHRASE:?set BACKUP_PASSPHRASE}"

mkdir -p "$BACKUP_DIR"

echo "[1/3] Dumping Supabase Postgres…"
# postgres:17 container so pg_dump matches the server version; NAS has Docker.
# (A pg_dump older than the server exits nonzero but can leave a tiny useless
#  dump behind — pipefail above turns that into a loud failure.)
docker run --rm postgres:17-alpine pg_dump "$SUPABASE_DB_URL" -Fc \
  --schema=public --schema=storage --no-owner \
  | gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback --passphrase-fd 3 3<<<"$BACKUP_PASSPHRASE" \
  > "$BACKUP_DIR/db_${STAMP}.dump.gpg"

echo "[2/3] Downloading document storage…"
docker run --rm \
  -e SUPABASE_URL -e SUPABASE_SERVICE_ROLE_KEY \
  -v "$SCRIPT_DIR:/scripts:ro" \
  python:3.12-alpine python /scripts/storage_backup.py \
  | gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback --passphrase-fd 3 3<<<"$BACKUP_PASSPHRASE" \
  > "$BACKUP_DIR/documents_${STAMP}.tar.gpg"

echo "[3/3] Pruning backups older than ${RETENTION_DAYS} days…"
find "$BACKUP_DIR" -name '*.gpg' -mtime "+${RETENTION_DAYS}" -delete

echo "Backup complete: $BACKUP_DIR (db_${STAMP}, documents_${STAMP})"

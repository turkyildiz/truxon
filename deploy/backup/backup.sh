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
# The URL (password included) must never appear on argv — argv is visible in
# `ps` to every process on the NAS. Split it into libpq PG* env vars on the
# host and hand those to the container; pg_dump's argv stays secret-free.
urldecode() { local d="${1//+/ }"; printf '%b' "${d//%/\\x}"; }
_rest="${SUPABASE_DB_URL#*://}"
_userinfo="${_rest%%@*}"; _hostpart="${_rest#*@}"
PGUSER="$(urldecode "${_userinfo%%:*}")"
PGPASSWORD="$(urldecode "${_userinfo#*:}")"
_hostport="${_hostpart%%/*}"
PGDATABASE="${_hostpart#*/}"; PGDATABASE="${PGDATABASE%%\?*}"
PGHOST="${_hostport%%:*}"; PGPORT="${_hostport##*:}"
[[ "$PGPORT" == "$PGHOST" ]] && PGPORT=5432
export PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
docker run --rm -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE \
  postgres:17-alpine pg_dump -Fc \
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

# Off-site immutable copy: upload the two encrypted files to a Backblaze B2
# bucket with Object Lock in COMPLIANCE mode. A retain-until date is stamped on
# each object, so nothing — not this key (even with deleteFiles), not full NAS
# root, not a Supabase compromise — can delete or alter it before it expires.
# This is the copy that survives ransomware. Needs B2_* in the env file.
if [[ -n "${B2_BUCKET:-}" && -n "${B2_KEY_ID:-}" && -n "${B2_APP_KEY:-}" ]]; then
  lock_days="${OFFSITE_LOCK_DAYS:-${RETENTION_DAYS}}"
  retain="$(date -u -d "+${lock_days} days" +%Y-%m-%dT%H:%M:%SZ)"
  echo "[off-site] Uploading immutable copy to B2 (${B2_BUCKET}, locked until ${retain})…"
  export AWS_ACCESS_KEY_ID="$B2_KEY_ID" AWS_SECRET_ACCESS_KEY="$B2_APP_KEY" AWS_DEFAULT_REGION="${B2_REGION:-us-east-005}"
  for f in "db_${STAMP}.dump.gpg" "documents_${STAMP}.tar.gpg"; do
    [ -f "$BACKUP_DIR/$f" ] || continue
    if docker run --rm \
        -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
        -v "$BACKUP_DIR/$f:/u/$f:ro" amazon/aws-cli \
        --endpoint-url "$B2_ENDPOINT" s3api put-object \
        --bucket "$B2_BUCKET" --key "nightly/$f" --body "/u/$f" \
        --object-lock-mode COMPLIANCE --object-lock-retain-until-date "$retain" >/dev/null; then
      echo "  off-site OK: $f"
    else
      echo "  WARNING: off-site upload failed for $f (local + snapshot copies still saved)"
    fi
  done
  unset AWS_SECRET_ACCESS_KEY
fi

# Tell the watchdog this run completed — it alarms if no heartbeat lands in 26h.
# The function has verify_jwt on (like the cron caller), so we must send the anon
# key as the platform Authorization header; the function then does its own
# WATCHDOG_REPORT_KEY check on the body. Needs SUPABASE_URL + SUPABASE_ANON_KEY +
# WATCHDOG_REPORT_KEY in the env file.
if [[ -n "${WATCHDOG_REPORT_KEY:-}" && -n "${SUPABASE_ANON_KEY:-}" ]]; then
  db_size="$(du -h "$BACKUP_DIR/db_${STAMP}.dump.gpg" 2>/dev/null | cut -f1)"
  curl -fsS -m 20 -X POST "${SUPABASE_URL}/functions/v1/watchdog" \
    -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H 'Content-Type: application/json' \
    -d "$(printf '{"heartbeat":"backup","key":"%s","detail":"db_%s (%s)"}' "$WATCHDOG_REPORT_KEY" "$STAMP" "${db_size:-?}")" \
    >/dev/null 2>&1 || echo "  (heartbeat ping failed — backup itself is fine)"
fi

echo "Backup complete: $BACKUP_DIR (db_${STAMP}, documents_${STAMP})"

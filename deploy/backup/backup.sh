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

# DR: mirror the (already GPG-encrypted) release-signing bundle offsite to the
# private "dr-vault" storage bucket, so a dev-box+NAS double loss cannot lose the
# app signing key (that would force a full fleet re-key). Encrypted at rest.
if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  for f in "$(dirname "$BACKUP_DIR")"/../release-signing/*.gpg /volume1/docker/truxon-backup/release-signing/*.gpg; do
    [ -f "$f" ] || continue
    curl -fsS -m 30 -X POST "${SUPABASE_URL}/storage/v1/object/dr-vault/release-signing/$(basename "$f")" \
      -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "x-upsert: true" -H "Content-Type: application/octet-stream" --data-binary "@$f" \
      >/dev/null 2>&1 && echo "  [dr-vault] offsite: $(basename "$f")" || echo "  (dr-vault upload failed for $(basename "$f"))"
  done
fi

# Offsite NAS replication (3-2-1's second site): mirror the encrypted set to
# the INDIANCREEK Synology over the tailnet. Key-based, rsync-over-SSH (the
# DSM rsync service must be enabled or Synology's patched rsync rejects the
# session AFTER ssh auth). Needs OFFSITE_HOST + OFFSITE_USER in the env file;
# the dedicated key lives next to the backups, never in the repo.
#
# This runs INSIDE the docker:cli (Alpine) scheduler container, which ships ssh
# but not rsync — so we shell out to a pinned sibling rsync image (built from
# deploy/backup/offsite-rsync/), exactly like pg_dump (postgres:17-alpine) and
# the B2 upload (amazon/aws-cli). Host key is PINNED via offsite_known_hosts
# next to the key (the container has no ~/.ssh trust store of its own) — seed it
# once with:  ssh-keyscan -H "$OFFSITE_HOST" > .ssh/offsite_known_hosts
if [[ -n "${OFFSITE_HOST:-}" && -n "${OFFSITE_USER:-}" ]]; then
  OFFSITE_SSH_DIR="${OFFSITE_SSH_DIR:-/volume1/docker/truxon-backup/.ssh}"
  OFFSITE_IMG="${OFFSITE_IMG:-truxon-offsite-rsync:1}"
  # run the sibling as the key's owner (host turkyildiz, uid 1000) — ssh rejects
  # a private key not owned by the running uid or root; HOME=/tmp so ssh doesn't
  # warn about a missing ~/.ssh (we pin UserKnownHostsFile explicitly anyway).
  OFFSITE_UID="${OFFSITE_UID:-1000}"
  # --bwlimit: an uncapped bulk rsync saturated the office uplink so hard the
  # NAS's OWN tailscale keepalives starved and it dropped off the tailnet
  # (2026-07-23 incident — Funnel/Valhalla/prodsql all dark mid-transfer).
  # Cap leaves the link breathable; nightly deltas are small anyway.
  OFFSITE_BWLIMIT="${OFFSITE_BWLIMIT:-3m}"
  # ssh inside the sibling container: mounted key + pinned known_hosts, strict.
  _rsh="ssh -i /ssh/offsite_rsync -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/ssh/offsite_known_hosts -o ConnectTimeout=20"
  offsite_ok=1
  docker run --rm --user "${OFFSITE_UID}:${OFFSITE_UID}" -e HOME=/tmp \
    -v "$BACKUP_DIR:/backups:ro" -v "$OFFSITE_SSH_DIR:/ssh:ro" \
    "$OFFSITE_IMG" \
    rsync -a --delete --bwlimit="$OFFSITE_BWLIMIT" -e "$_rsh" --include='*.gpg' --exclude='*' \
      /backups/ "${OFFSITE_USER}@${OFFSITE_HOST}:truxon-offsite/backups/" \
    || { offsite_ok=0; echo "  WARNING: offsite backups rsync failed"; }
  docker run --rm --user "${OFFSITE_UID}:${OFFSITE_UID}" -e HOME=/tmp \
    -v "/volume1/docker/truxon-backup/release-signing:/signing:ro" -v "$OFFSITE_SSH_DIR:/ssh:ro" \
    "$OFFSITE_IMG" \
    rsync -a --bwlimit="$OFFSITE_BWLIMIT" -e "$_rsh" --include='*.gpg' --exclude='*' \
      /signing/ "${OFFSITE_USER}@${OFFSITE_HOST}:truxon-offsite/release-signing/" \
    || { offsite_ok=0; echo "  WARNING: offsite release-signing rsync failed"; }
  if [[ "$offsite_ok" == 1 && -n "${WATCHDOG_REPORT_KEY:-}" && -n "${SUPABASE_ANON_KEY:-}" ]]; then
    echo "  [offsite] mirrored to ${OFFSITE_HOST}"
    curl -fsS -m 20 -X POST "${SUPABASE_URL}/functions/v1/watchdog" \
      -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
      -H "apikey: ${SUPABASE_ANON_KEY}" \
      -H 'Content-Type: application/json' \
      -d "$(printf '{"heartbeat":"offsite","key":"%s","detail":"rsync db_%s"}' "$WATCHDOG_REPORT_KEY" "$STAMP")" \
      >/dev/null 2>&1 || true
  fi
fi

echo "Backup complete: $BACKUP_DIR (db_${STAMP}, documents_${STAMP})"

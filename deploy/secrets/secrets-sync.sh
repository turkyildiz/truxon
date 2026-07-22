#!/usr/bin/env bash
# Sync the encrypted Truxon secrets vault between the local machine and the NAS.
# The .kdbx is AES-256/Argon2 encrypted, so every copy is safe at rest.
#
#   secrets-sync.sh push    local → NAS primary  (+ timestamped versions on both)
#   secrets-sync.sh pull    NAS  → local working copy
#   secrets-sync.sh status  show where copies are and their timestamps
#
# Layout:
#   local working : ~/dev-tools/secrets/truxon-secrets.kdbx
#   local backups : ~/dev-tools/secrets/backups/truxon-secrets-<ts>.kdbx
#   NAS primary   : /volume1/docker/truxon-backup/secrets/truxon-secrets.kdbx
#   NAS versions  : /volume1/docker/truxon-backup/secrets/versions/truxon-secrets-<ts>.kdbx
# Offsite (B2): the NAS's own nightly backup can sweep the secrets/ dir — see README.
set -euo pipefail

DB="${SECRETS_DB:-$HOME/dev-tools/secrets/truxon-secrets.kdbx}"
LOCAL_BK="$(dirname "$DB")/backups"
NAS="${SECRETS_NAS:-turkyildiz@100.89.140.98}"
NAS_DIR="${SECRETS_NAS_DIR:-/volume1/docker/truxon-backup/secrets}"
TS="$(date +%Y%m%d-%H%M%S)"
cmd="${1:-status}"

verify() { keepassxc-cli db-info "$1" >/dev/null 2>&1 || { echo "warn: $1 doesn't look like a valid kdbx (or needs a password to inspect)"; }; }

case "$cmd" in
  push)
    [ -f "$DB" ] || { echo "no local vault at $DB — run secrets-init.sh first"; exit 1; }
    mkdir -p "$LOCAL_BK"
    cp -a "$DB" "$LOCAL_BK/truxon-secrets-$TS.kdbx"
    # Transfer via `ssh cat` (not scp) — Synology's SFTP is chrooted, so absolute
    # /volume1 paths fail over scp but resolve fine through the login shell.
    ssh "$NAS" "mkdir -p $NAS_DIR/versions && cat > $NAS_DIR/truxon-secrets.kdbx && cp -a $NAS_DIR/truxon-secrets.kdbx $NAS_DIR/versions/truxon-secrets-$TS.kdbx && chmod 600 $NAS_DIR/truxon-secrets.kdbx $NAS_DIR/versions/*.kdbx" < "$DB"
    ls -1t "$LOCAL_BK"/truxon-secrets-*.kdbx 2>/dev/null | tail -n +31 | xargs -r rm -f
    echo "pushed → NAS primary + local backup  ($TS)"
    ;;
  pull)
    mkdir -p "$(dirname "$DB")"
    [ -f "$DB" ] && cp -a "$DB" "$LOCAL_BK/truxon-secrets-prepull-$TS.kdbx" 2>/dev/null || true
    ssh "$NAS" "cat $NAS_DIR/truxon-secrets.kdbx" > "$DB"
    chmod 600 "$DB"
    echo "pulled NAS → local  ($DB)"
    ;;
  status)
    echo "local working : $DB $( [ -f "$DB" ] && stat -c '(%y, %s bytes)' "$DB" || echo '(missing)')"
    echo "local backups : $(ls -1 "$LOCAL_BK"/*.kdbx 2>/dev/null | wc -l) file(s) in $LOCAL_BK"
    echo -n "NAS primary   : "; ssh "$NAS" "ls -l --time-style=+%Y-%m-%d\ %H:%M $NAS_DIR/truxon-secrets.kdbx 2>/dev/null || echo '(none yet)'"
    echo -n "NAS versions  : "; ssh "$NAS" "ls -1 $NAS_DIR/versions/*.kdbx 2>/dev/null | wc -l"
    ;;
  *) echo "usage: secrets-sync.sh {push|pull|status}"; exit 2 ;;
esac

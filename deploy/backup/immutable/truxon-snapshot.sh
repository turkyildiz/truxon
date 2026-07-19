#!/usr/bin/env bash
# Root-run: take a READ-ONLY btrfs snapshot of the encrypted backups into a
# root-only immutable store the backup account cannot reach or delete, then
# prune snapshots older than KEEP_DAYS.
#
# This is the ransomware-resistant "1" in 3-2-1-1-0: even a full compromise of
# the backup account or the scheduler container cannot encrypt or delete these
# — the store is root-owned mode 700, and `btrfs subvolume delete` needs root.
# (A full ROOT compromise of the NAS could still remove them; the off-site
#  object-locked copy is what covers that. This raises the bar from "backup
#  credential" to "root".)
set -euo pipefail

SRC=/volume1/docker/truxon-backup/backups
STORE=/volume1/backups-immutable
KEEP_DAYS="${KEEP_DAYS:-30}"
LOG=/var/log/truxon-snapshot.log
STAMP="$(date +%Y%m%d_%H%M)"

mkdir -p "$STORE"; chown root:root "$STORE"; chmod 700 "$STORE"

if ! btrfs subvolume show "$SRC" >/dev/null 2>&1; then
  echo "[$(date '+%F %T')] ERROR: $SRC is not a btrfs subvolume — run immutable-setup.sh first" | tee -a "$LOG" >&2
  exit 1
fi

btrfs subvolume snapshot -r "$SRC" "$STORE/backups_$STAMP" >/dev/null
echo "[$(date '+%F %T')] snapshot taken: $STORE/backups_$STAMP" >> "$LOG"

# Prune read-only snapshots older than KEEP_DAYS (lexicographic on fixed-width stamp).
cutoff="$(date -d "-${KEEP_DAYS} days" +%Y%m%d_%H%M)"
for s in "$STORE"/backups_*; do
  [ -d "$s" ] || continue
  ts="$(basename "$s")"; ts="${ts#backups_}"
  if [[ "$ts" < "$cutoff" ]]; then
    btrfs subvolume delete "$s" >/dev/null && echo "[$(date '+%F %T')] pruned $s" >> "$LOG"
  fi
done

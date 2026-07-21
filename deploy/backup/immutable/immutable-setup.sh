#!/usr/bin/env bash
# ONE-TIME root setup for ransomware-resistant immutable backup snapshots.
# Safe to re-run (idempotent). Review before running with sudo.
#
#   sudo bash /volume1/docker/truxon-backup/scheduler/immutable-setup.sh
#
# What it does:
#   1. Converts the backups dir into a btrfs subvolume (needed to snapshot it),
#      preserving all existing backups. Never deletes your data — if anything is
#      left un-moved it stops and tells you.
#   2. Creates a root-only immutable store /volume1/backups-immutable (mode 700).
#   3. Installs the recurring snapshot job at /usr/local/sbin/truxon-snapshot.sh.
#   4. Adds a root cron (/etc/cron.d/truxon-snapshot) to snapshot daily at 02:45
#      (after the ~11-min nightly backup at 02:00).
#   5. Takes one snapshot now to verify.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo (need root)"; exit 1; }

SRC=/volume1/docker/truxon-backup/backups
STORE=/volume1/backups-immutable
SCHED=/volume1/docker/truxon-backup/scheduler

echo "[1/5] backups dir -> btrfs subvolume"
if btrfs subvolume show "$SRC" >/dev/null 2>&1; then
  echo "      already a subvolume, skipping"
else
  [ -e "${SRC}.old" ] && { echo "      ${SRC}.old already exists — resolve manually"; exit 1; }
  mv "$SRC" "${SRC}.old"
  btrfs subvolume create "$SRC"
  chown turkyildiz:admin "$SRC"; chmod 750 "$SRC"
  shopt -s dotglob nullglob
  mv "${SRC}.old"/* "$SRC"/ 2>/dev/null || true
  if rmdir "${SRC}.old" 2>/dev/null; then
    echo "      converted; data preserved"
  else
    echo "      WARNING: ${SRC}.old not empty — left in place, inspect it. Aborting."; exit 1
  fi
fi

echo "[2/5] root-only immutable store $STORE"
mkdir -p "$STORE"; chown root:root "$STORE"; chmod 700 "$STORE"

echo "[3/5] install snapshot job"
install -m 700 -o root -g root "$SCHED/truxon-snapshot.sh" /usr/local/sbin/truxon-snapshot.sh

echo "[4/5] install root cron (daily 02:45)"
cat > /etc/cron.d/truxon-snapshot <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
45 2 * * * root /usr/local/sbin/truxon-snapshot.sh
CRON
chmod 644 /etc/cron.d/truxon-snapshot

echo "[5/5] take one snapshot now"
/usr/local/sbin/truxon-snapshot.sh

echo
echo "DONE. Immutable read-only snapshots (root-only, undeletable by the backup account):"
ls -ld "$STORE"
btrfs subvolume list /volume1 | grep -E "backups_[0-9]" || true

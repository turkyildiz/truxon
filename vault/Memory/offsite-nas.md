---
name: offsite-nas
description: "INDIANCREEK — a 2nd Synology at a different site for true offsite backup. On the tailnet via a Docker Tailscale container; waiting only on owner to authorize the rsync key."
metadata:
  type: project
---

**Second Synology NAS for real geographic DR** (different building), added 2026-07-22. Completes 3-2-1: local [[nas-access|aida-nas]] + **INDIANCREEK (offsite)** + Supabase `dr-vault`. Everything replicated is already GPG-encrypted.

**Identity:** DSM name **INDIANCREEK**, QuickConnect id **unilogistix** (`unilogistix.quickconnect.to`), 62 TB. Tailnet node **`indiancreek-offsite` = `100.99.140... → 100.99.180.17`**, SSH user **turkyildiz**. Reachable from aida-nas/ikedev over the tailnet (direct path, ~29 ms).

**Connectivity gotcha (important):** the native **Tailscale DSM package UI is BLOCKED over QuickConnect** ("cannot be accessed when connected via QuickConnect"). Solution = run **Tailscale as a Docker container** in **Container Manager** (project **`tailscale`**, `/volume1/docker/compose.yaml`, host-network, `cap_add NET_ADMIN,SYS_MODULE`, `/dev/net/tun`, state at `/volume1/docker/tailscale/state`, `TS_USERSPACE=false`) authenticated with a **single-use auth key** (spent). Host-mode → the NAS host itself joins the tailnet, so host SSH is reachable at `100.99.180.17`. **Gotcha:** Container Manager does NOT auto-create bind-mount dirs — had to create `docker/tailscale/state` in File Station first. Host **SSH is enabled** (Control Panel → Terminal & SNMP).

**Replication key:** generated on aida-nas at `/volume1/docker/truxon-backup/.ssh/offsite_rsync(.pub)`, pubkey `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINGtk5Lju49Ltx1pQ26GyBC5olR0P6UvAdT++wnMuxYa aida-nas->indiancreek-offsite`.

**Key AUTHORIZED + working (2026-07-23):** owner ran the 3-liner + `chmod 755 "$HOME"` (Synology StrictModes also rejects a group-writable HOME — needed both). `ssh -i offsite_rsync -o IdentitiesOnly=yes turkyildiz@100.99.180.17` works from aida-nas. Target dirs created: **`/volume1/homes/turkyildiz/truxon-offsite/{backups,release-signing}`** (no write perm on /volume1 root without DSM, home dir is same volume). ⚠ Volume is **99% full (1.1 TB free of 63 TB)** — fine for our ~8 GB GPG set, flagged to owner.

**rsync service ENABLED** (owner) → **REPLICATION LIVE, VERIFIED 2026-07-23**: first full sync complete (7.6 GB, 17 backup files + signing bundle), **sha256 spot-verified byte-identical** (signing 69b8bae4…, db dump 7a3fb8f6…). Capped at `--bwlimit=3m` + nice/ionice after the incident. Nightly rsync wired into aida-nas `scripts/backup.sh` (runs after the 02:00 backup), posts `{heartbeat:'offsite'}` on success; watchdog `offsite_fresh` check live (`offsite_stale=false`, alarms >26h stale). 3-2-1 now true across two buildings + Supabase `dr-vault`. Note: INDIANCREEK volume was 99% full (1.1 TB free) — fine for this set, owner may want to prune. Runbook: `deploy/backup/OFFSITE-NAS-SETUP.md`. Related: [[disaster-recovery]], [[nas-access]], [[secrets-vault]].

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

**rsync service ENABLED** (owner, 2026-07-23) — Synology's patched server-side rsync refuses non-root rsync-over-SSH until **Control Panel → File Services → rsync → Enable rsync service** is ticked. After that, key rsync works.

**⚠ INCIDENT 2026-07-23 ~01:00:** the FIRST full sync (7.6 GB, uncapped) **knocked aida-nas off the tailnet** — uplink saturation starved its own tailscale keepalives → node dark ≥45 min, Funnel/Valhalla/models/prodsql all unreachable (fleet-facing NAS services down; cloud watchdog still alive and will alarm on stale heartbeats). Fix committed to repo backup.sh: **`--bwlimit` (default `3m`, env `OFFSITE_BWLIMIT`)** on both rsyncs. ⚠ NAS copy still has the uncapped version — FIRST ACTION when reachable: kill stale rsyncs, deploy capped backup.sh, re-run first sync capped, verify tailscale + funnel. **Interesting discovery:** INDIANCREEK is currently on the DEV-BOX LAN (192.168.40.11, ssh open) — while it sits here, a capped LAN-side seed is possible; the tailnet path matters once it moves offsite.

**THEN Claude finishes:** (1) first full sync of `backups/*.gpg` + `release-signing/*.gpg` + sha256 verify; (2) nightly `rsync -a --delete` into aida-nas `scripts/backup.sh` + repo `deploy/backup/backup.sh` (after the 02:00 backup, tailnet only, `-e ssh -i offsite_rsync -o IdentitiesOnly=yes`); (3) offsite heartbeat (source `offsite`) + watchdog `offsite_fresh` check. Runbook: `deploy/backup/OFFSITE-NAS-SETUP.md`. Related: [[disaster-recovery]], [[nas-access]], [[secrets-vault]].

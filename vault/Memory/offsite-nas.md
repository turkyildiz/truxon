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

**⚠ PENDING — owner (doing it when home):** authorize that key on INDIANCREEK (Synology StrictModes needs exact perms; File Station can't set them reliably, so 3-liner):
```
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINGtk5Lju49Ltx1pQ26GyBC5olR0P6UvAdT++wnMuxYa aida-nas->indiancreek-offsite' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**THEN Claude finishes (CLI, no browser):** (1) verify `ssh -i offsite_rsync turkyildiz@100.99.180.17`; (2) create `truxon-offsite` shared folder; (3) add nightly `rsync -a --delete` of `backups/*.gpg` + `release-signing/*.gpg` → INDIANCREEK into aida-nas `scripts/backup.sh` (right after 02:00 backup, tailnet only); (4) offsite heartbeat (source `indiancreek`) + a watchdog `offsite_fresh` check; (5) first full sync + sha256 verify. Runbook: `deploy/backup/OFFSITE-NAS-SETUP.md`. Related: [[disaster-recovery]], [[nas-access]], [[secrets-vault]].

# Offsite NAS (Synology, different site) — onboarding

Goal: the primary NAS rsyncs its **already-GPG-encrypted** nightly backups
(`backups/*.gpg` + `release-signing/*.gpg`) to this offsite NAS over Tailscale.
True 3-2-1: local NAS + **offsite NAS (different building)** + Supabase `dr-vault`.

## You do these on the offsite Synology (one time)

**1. Join Tailscale (same account as the other machines)**
- Package Center → search **Tailscale** → Install → Open → **Sign in** with the same account.
- (If not in Package Center, get the `.spk` from tailscale.com/download/synology and install manually.)

**2. Enable SSH**
- Control Panel → **Terminal & SNMP** → check **Enable SSH service** → Apply.
- Control Panel → User & Group → make sure the account you'll give me is in the **administrators** group (Synology only allows admins to SSH), and **User Home service is enabled** (Control Panel → User & Group → Advanced → Enable user home service) — key-based login needs a home dir.

**3. Make a target folder**
- Create a shared folder, e.g. **`truxon-offsite`** (File Station → Create). It'll hold `backups/` and `release-signing/`. Path will be `/volume1/truxon-offsite/`.

## Then give me two things
- The offsite NAS **Tailscale IP** (`tailscale ip -4` in SSH, or from the Tailscale admin console) — a `100.x.x.x`.
- The **SSH username** (an admin account) I should use.

## What I do next (automated, no more input from you)
1. From the primary NAS, generate a dedicated **replication SSH key** and give you its one-line public key to add on the offsite NAS (Synology: the user's `~/.ssh/authorized_keys`) — or I add it if you hand me SSH once.
2. Wire a nightly `rsync -a --delete` of the encrypted set into `backup.sh` (runs right after the 02:00 backup), over the tailnet only.
3. Add an offsite **heartbeat + watchdog check** so you're alerted if the offsite copy goes stale.
4. Run a first full sync and **verify byte-for-byte** (sha256).

Everything transferred is GPG-encrypted, so it's safe in flight and at rest on the offsite box.

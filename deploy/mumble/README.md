# Truxon PTT — Mumble voice (dispatcher ↔ driver push-to-talk)

**Status (2026-07-17):** Murmur server **live and running** on the UGREEN NAS
(UGOS Docker → Project `truxon-mumble`, container `truxon-mumble`, image
`mumblevoip/mumble-server:latest`). Listens on **port 64738** (TCP control +
UDP voice). Data persists in the `mumble-data` Docker volume.

Compose source of truth: [`docker-compose.yml`](docker-compose.yml).

---

## Credentials (owner — store in your password manager, then delete from chat)

Generated at deploy time and set as env vars in the NAS project:

- **Superuser** (server admin, used from a Mumble client to manage channels/ACLs)
  - username `SuperUser`, password: **see the value I gave you in chat** (starts `qFlXz…`)
- **Server join password** (every client must enter this to connect)
  - value: **see chat** (starts `78tJt…`)

These are also visible/editable in UGOS → Docker → Project `truxon-mumble` → env.
Rotate anytime by editing the project and redeploying.

---

## What works right now vs. what needs one router change

| Who | Reachability | Needs |
|-----|--------------|-------|
| **Office dispatchers** (same LAN as the NAS) | ✅ works now | connect to `NAS_LAN_IP:64738` |
| **Drivers on tablets over LTE** (remote) | ⛔ not yet | see below |

**Chosen: Tailscale VPN.** Drivers join a private network instead of us
exposing any port to the internet. Server-side is **deployed** on the NAS
(Project `truxon-tailscale`, host mode — see `tailscale-compose.yml`). It's
verified working but **stopped, waiting on an auth key** — the container's boot
supervisor kills interactive browser login after 60s, so it needs a key.

### Finish Tailscale (owner, ~5 min)

1. **Create a free Tailscale account** at https://login.tailscale.com (sign in
   with Google/Microsoft/email). Free plan covers up to 100 devices — plenty.
2. **Generate an auth key:** admin console → **Settings → Keys → Generate auth
   key**. Make it **Reusable** and **Pre-approved** (and consider **Ephemeral:
   off** so the NAS stays registered). Copy it (`tskey-auth-…`).
3. **Add it to the NAS project:** UGOS → Docker → Project `truxon-tailscale` →
   edit → in the container's `environment` list add:
   `TS_AUTHKEY=tskey-auth-…` → **Deploy**. The container will start, authenticate,
   and the NAS appears in your Tailscale admin console as **aida-nas** with a
   `100.x.y.z` tailnet IP. Note that IP.
4. **Put each device on the tailnet:** install the **Tailscale app** on every
   driver tablet and dispatcher machine, sign in to the same account (or use a
   reusable key). They all get `100.x` IPs and can reach the NAS.
5. **Point Mumla/Mumble at the NAS tailnet IP:** host = `100.x.y.z` (the NAS's
   Tailscale IP), port 64738, server join password. Done — remote drivers now
   reach Mumble over the VPN, encrypted, nothing exposed publicly.

(Office dispatchers on the LAN can keep using `NAS_LAN_IP:64738` — both work.)

I set the whole thing up to this point; only the account + key are yours to
create (I don't handle credentials). Tell me when the key's in and I'll verify
the NAS shows up on the tailnet and Mumble answers on its 100.x address.

---

## Client apps

- **Drivers (Samsung tablets, Android):** install **Mumla** from the Play Store
  (actively maintained Mumble client). Add server: host = your DDNS/VPN address,
  port 64738, username = the driver's name, password = the server join password.
  Map **push-to-talk** to a big on-screen button (Mumla → Settings → Push to
  Talk). Kiosk/Knox can pin Mumla alongside the Truxon companion app.
- **Dispatchers (desktop):** install **Mumble** (mumble.info) on Windows/Mac.
  Same server details. Push-to-talk bound to a key, or use voice-activated.

## Channel structure (set once, from a SuperUser client session)

Connect as `SuperUser`, then create channels: **Dispatch** (office ↔ any driver),
**All Drivers** (broadcast), and optionally per-region or per-truck sub-channels.
Set ACLs so drivers can speak in Dispatch/All Drivers but not administer. This is
a 10-minute one-time setup in the client — walk through it together when ready.

## Phase 2 (later)

Auto-provision Mumble accounts from Truxon (when a driver is added, create their
Mumble login + push their credentials to the companion app) so there's no manual
account juggling. Not built yet — noted in the Trux roadmap.

## Operate

- Start/stop/restart: UGOS → Docker → Project `truxon-mumble`.
- Logs: UGOS → Docker → Container `truxon-mumble` → (open container) → Log.
- Backup: the `mumble-data` volume holds registrations + channel config; it's
  small and re-creatable. Add it to the NAS snapshot set if you want it retained.

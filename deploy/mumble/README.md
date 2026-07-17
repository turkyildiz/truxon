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

**The one owner decision for remote drivers:** the NAS is only reachable from
the office LAN today. For drivers on the road, the server must be reachable from
the internet. Options, best first:

1. **VPN (recommended, most secure):** run WireGuard/Tailscale so tablets join
   the private network and reach `NAS_LAN_IP:64738` — nothing exposed publicly.
   Tailscale has a UGOS/Docker option and is the cleanest for a fleet.
2. **Port-forward (simplest):** on the office router, forward **64738 TCP *and*
   UDP** to the NAS's LAN IP, and use a **DDNS** hostname (the NAS has built-in
   DDNS under Control Panel → External Access; note the UGREEN `*.ug.link`
   relay is HTTP-only and will **not** carry Mumble's port — you need real
   port-forwarding + a DDNS A-record or your office's static IP).
   Security: set a strong server join password (done) and consider limiting
   source IPs if your carrier allows.

I did **not** touch the router — exposing a port to the internet is your call.
Tell me which path you want and I'll write the exact steps (or set up Tailscale).

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

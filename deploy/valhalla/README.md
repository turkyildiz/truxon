# Valhalla on the NAS — truck-safe routing for the companion app

Decision (2026-07-21): Valhalla lives on the NAS. Tablets reach it through
**Tailscale Funnel** — Tailscale stays SERVER-side only, tablets stay
one-app, the router is never touched.

## Bring-up (once, when NAS SSH access exists)

1. Copy this directory to the NAS; `./setup.sh` (full lower-48, ~9GB
   download) or `./setup.sh midwest` (corridor states, much lighter build).
   Graph build takes hours on first run — watch `docker logs -f
   truxon-valhalla` for "Tile extract successful". Rough needs: 8GB+ RAM
   during build (midwest fits smaller), 20-60GB disk.
2. `./smoke.sh` — Chicago→Columbus as a 13'6"/80k truck must return a route.
3. Publish it: `tailscale funnel --bg 8002` on the NAS → note the public
   `https://<nas-name>.<tailnet>.ts.net` URL it prints.
4. `./smoke.sh https://<that-url>` from anywhere — same result over the
   public endpoint.

## Wire the app

Add to the release build (publish-release.sh dart-defines):
    --dart-define=VALHALLA_URL=https://<nas-name>.<tailnet>.ts.net
The map screen switches from bearing-line to real truck routes on the next
OTA update. No app-code change needed — the client shipped ready.

## Refresh

OSM data ages gently; re-run setup.sh quarterly (it re-downloads and the
container rebuilds tiles). Add to the NAS crontab when convenient.

## Still blocked on

NAS SSH access (UGOS) — the standing owner-owed item. Everything in this
directory is ready to run the day that lands. The doc-rag worker's
CRON_SECRET handoff rides the same visit.

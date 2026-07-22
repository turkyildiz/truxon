#!/bin/sh
# Entry point for the truxon-vision-enrich container (node:18 + --network host).
# Installs poppler once, then loops forever: run the scanned-rate-con vision
# backfill ONLY when the NAS is idle (Jellyfin/Plex transcoding pins the CPU and
# starves minicpm-v). Blanks-only + resumable, so skipping/repeating is safe.
# --network host lets it reach both the signed PDF URLs and Ollama at 127.0.0.1.
cd /app || exit 1
# Install poppler once, and only if it isn't already baked into the image
# (truxon-vision bakes it — then this is a no-op, no floating install: M-7).
command -v pdftoppm >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq --no-install-recommends poppler-utils >/dev/null 2>&1; }
LOG="logs/vision_cron.log"
while true; do
  L=$(awk '{print int($1)}' /proc/loadavg)
  if [ "$L" -lt 6 ]; then
    echo "$(date '+%F %T') run (load $L)" >> "$LOG"
    node vision-enrich.mjs >> "$LOG" 2>&1
  else
    echo "$(date '+%F %T') skip (load $L too high)" >> "$LOG"
  fi
  sleep 1800
done

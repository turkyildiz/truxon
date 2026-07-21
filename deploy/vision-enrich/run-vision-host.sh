#!/bin/sh
# Overnight vision-enrichment backfill, run DIRECTLY ON THE NAS HOST (node 18 +
# poppler are installed there). The container path (run-vision.sh) hit a
# "fetch failed" quirk on this box; running on the host works and reaches both
# the signed PDF URLs and Ollama at 127.0.0.1.
#
# Load guard: the NAS also runs Jellyfin/Plex media transcoding, which pins the
# CPU. minicpm-v on a starved CPU crawls, so we SKIP the run when the 1-min load
# average is high and let a later window catch it. Blanks-only + resumable, so
# skipping/repeating is safe.
cd /volume1/docker/truxon-vision || exit 1
LOAD1=$(awk '{print int($1)}' /proc/loadavg)
if [ "$LOAD1" -gt 6 ]; then
  echo "$(date '+%F %T') skip: load $LOAD1 too high (media transcoding?)" >> logs/vision_host_$(date +%Y%m).log
  exit 0
fi
flock -n /tmp/truxon-vision-host.lock node vision-enrich.mjs >> logs/vision_host_$(date +%Y%m).log 2>&1
find logs -name 'vision_host_*.log' -mtime +90 -delete 2>/dev/null || true

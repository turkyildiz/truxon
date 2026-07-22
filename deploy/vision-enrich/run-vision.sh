#!/bin/sh
# Cron/manual wrapper (runs inside a poppler-capable container): rasterize each
# customer's rate cons and fill blanks via the customer-enrich vision pipeline.
cd /volume1/docker/truxon-vision
LOG="logs/vision_$(date +%Y%m).log"
{
  echo "===== $(date '+%F %T') vision enrich start ====="
  # Prefer the pre-baked image (VISION_IMAGE=truxon-vision) with poppler already
  # inside — then no apt runs per job. On the bare Playwright image, install
  # poppler only if pdftoppm is missing (M-7).
  flock -n .run.lock docker run --rm \
    -v /volume1/docker/truxon-vision:/app -w /app --ipc=host --network host \
    "${VISION_IMAGE:-mcr.microsoft.com/playwright:v1.61.1-jammy}" \
    bash -c "command -v pdftoppm >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq --no-install-recommends poppler-utils >/dev/null 2>&1; }; node vision-enrich.mjs"
  echo "===== $(date '+%F %T') vision enrich end (rc=$?) ====="
} >>"$LOG" 2>&1
find logs -name 'vision_*.log' -mtime +90 -delete 2>/dev/null || true

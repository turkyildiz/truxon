#!/bin/sh
cd /volume1/docker/truxon-tolls
LOG="logs/tolls_$(date +%Y%m).log"; mkdir -p logs
{
  echo "===== $(date '+%F %T') toll fetch start ====="
  # Prefer the pre-baked pinned image (TOLLS_IMAGE=truxon-tolls) so no install
  # runs per job. If we're still on the bare python image, install the PINNED
  # requirement (never a floating `latest`) only when paramiko is absent — M-7.
  flock -n /tmp/truxon-tolls.lock docker run --rm --network host \
    -v /volume1/docker/truxon-tolls:/w -w /w "${TOLLS_IMAGE:-python:3.11-slim}" \
    sh -c "python3 -c 'import paramiko' 2>/dev/null || pip install --no-cache-dir -q -r requirements.txt; python3 fetch-tolls.py"
  echo "===== $(date '+%F %T') toll fetch end (rc=$?) ====="
} >>"$LOG" 2>&1
find logs -name 'tolls_*.log' -mtime +90 -delete 2>/dev/null || true

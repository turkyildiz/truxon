#!/bin/sh
cd /volume1/docker/truxon-tolls
LOG="logs/tolls_$(date +%Y%m).log"; mkdir -p logs
{
  echo "===== $(date '+%F %T') toll fetch start ====="
  flock -n /tmp/truxon-tolls.lock docker run --rm --network host \
    -v /volume1/docker/truxon-tolls:/w -w /w python:3.11-slim \
    sh -c "pip install -q paramiko 2>/dev/null; python3 fetch-tolls.py"
  echo "===== $(date '+%F %T') toll fetch end (rc=$?) ====="
} >>"$LOG" 2>&1
find logs -name 'tolls_*.log' -mtime +90 -delete 2>/dev/null || true

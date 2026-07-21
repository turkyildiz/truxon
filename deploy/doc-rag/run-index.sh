#!/bin/sh
# Cron wrapper (runs inside truxon-scheduler): embed any not-yet-indexed
# documents (driver PODs, drive files) via a one-shot node container.
# Host network so 127.0.0.1:11434 reaches ollama. flock prevents overlap
# with a long first-run backfill; monthly logs.
cd /volume1/docker/truxon-rag
LOG="logs/index_$(date +%Y%m).log"
{
  echo "===== $(date "+%F %T") rag index start ====="
  flock -n /tmp/truxon-rag-index.lock docker run --rm --network host \
    -v /volume1/docker/truxon-rag:/app -w /app \
    truxon-rag-node node index-docs.mjs
  echo "===== $(date "+%F %T") rag index end (rc=$?) ====="
} >>"$LOG" 2>&1
find logs -name "index_*.log" -mtime +90 -delete 2>/dev/null || true

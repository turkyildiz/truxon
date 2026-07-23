#!/bin/sh
set -a; . /etc/truxon-heartbeat.env; set +a
[ -n "$WATCHDOG_REPORT_KEY" ] || exit 0
OLL=$(systemctl is-active ollama 2>/dev/null)
GPU=$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,memory.used --format=csv,noheader 2>/dev/null | head -1 | tr -d " ")
curl -fsS -m 20 -X POST "$SUPABASE_URL/functions/v1/watchdog" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d "$(printf "{\"heartbeat\":\"lynx\",\"key\":\"%s\",\"detail\":\"ollama=%s gpu=%s\"}" "$WATCHDOG_REPORT_KEY" "$OLL" "$GPU")" \
  >/dev/null 2>&1 || true

# keep the heavy model warm: after a vision job evicts it (MAX_LOADED_MODELS=1)
# this re-loads qwen2.5:7b so Forest heavy calls never pay the ~8s cold start
curl -fsS -m 60 http://127.0.0.1:11434/api/generate -d "{\"model\":\"qwen2.5:7b\",\"prompt\":\"ok\",\"options\":{\"num_predict\":1}}" >/dev/null 2>&1 || true

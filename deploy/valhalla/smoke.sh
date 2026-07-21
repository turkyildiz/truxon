#!/usr/bin/env bash
# Chicago -> Columbus as a 13'6" / 80k-lb truck; expect a route, not an error.
set -euo pipefail
HOST="${1:-http://localhost:8002}"
curl -sf "$HOST/route" -d '{
  "locations":[{"lat":41.88,"lon":-87.63},{"lat":39.96,"lon":-83.00}],
  "costing":"truck",
  "costing_options":{"truck":{"height":4.11,"width":2.6,"length":21.0,"weight":36.28}},
  "units":"miles"}' | python3 -c "
import json,sys
t=json.load(sys.stdin)['trip']['summary']
print(f\"OK: {t['length']:.0f} mi, {t['time']/3600:.1f} h — truck routing works\")"

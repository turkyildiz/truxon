#!/usr/bin/env bash
# One-shot Valhalla bring-up on the NAS. Run from deploy/valhalla/.
#   ./setup.sh              # lower-48 (~9GB download, hours of graph build)
#   ./setup.sh midwest      # corridor subset (IL/IN/OH/MI/WI/MO/IA + neighbors)
set -euo pipefail
mkdir -p data

if [[ "${1:-us}" == "midwest" ]]; then
  # Geofabrik state extracts merge automatically at build time.
  for s in illinois indiana ohio michigan wisconsin missouri iowa kentucky \
           pennsylvania minnesota; do
    [ -f "data/$s.osm.pbf" ] || \
      curl -fL -o "data/$s.osm.pbf" \
        "https://download.geofabrik.de/north-america/us/$s-latest.osm.pbf"
  done
else
  [ -f data/us-latest.osm.pbf ] || \
    curl -fL -o data/us-latest.osm.pbf \
      "https://download.geofabrik.de/north-america/us-latest.osm.pbf"
fi

docker compose up -d
echo "Graph build runs inside the container now (docker logs -f truxon-valhalla)."
echo "When 'Tile extract successful' appears, test with ./smoke.sh"

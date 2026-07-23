#!/bin/bash
# Install the trained hey_forest openWakeWord model into the NAS gateway
# and switch the Forest assist pipeline to it.
set -euo pipefail
S=/tmp/claude-1000/-home-ilker-DEV/5000f4c3-637a-49c7-8f1a-514392bdef3c/scratchpad

echo "=== fetch model from Lynx ==="
scp -q lynx:~/forest-wakeword/hey_forest_model/hey_forest.tflite "$S/hey_forest.tflite"
ls -la "$S/hey_forest.tflite"

echo "=== install on NAS ==="
scp -q "$S/hey_forest.tflite" turkyildiz@100.89.140.98:/volume1/docker/forest-voice/oww-data/custom/hey_forest.tflite
ssh turkyildiz@100.89.140.98 'docker restart forest-openwakeword && sleep 5 && docker logs forest-openwakeword 2>&1 | tail -3'

echo "=== switch pipeline wake word ==="
cd "$S" && .venv/bin/python - <<'PY'
import json, pathlib
from websocket import create_connection

tok = pathlib.Path("forest-ha-longlived.token").read_text().strip()
ws = create_connection("ws://100.89.140.98:8123/api/websocket", timeout=30)
ws.recv(); ws.send(json.dumps({"type": "auth", "access_token": tok}))
assert json.loads(ws.recv())["type"] == "auth_ok"
mid = 0
def call(payload):
    global mid; mid += 1
    ws.send(json.dumps({"id": mid, **payload}))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == mid and r.get("type") == "result":
            assert r["success"], r
            return r["result"]

pipes = call({"type": "assist_pipeline/pipeline/list"})
pipe = next(p for p in pipes["pipelines"] if p["name"] == "Forest")
pipe["wake_word_id"] = "hey_forest"
pid = pipe.pop("id")
call({"type": "assist_pipeline/pipeline/update", "pipeline_id": pid, **pipe})
print("pipeline now wakes on:", call({"type": "assist_pipeline/pipeline/list"})["pipelines"][-1].get("wake_word_id") or "?")
ws.close()
PY
echo "INSTALL DONE"

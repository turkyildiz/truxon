# Forest voice gateway (NAS)

"Hey Forest" smart-speaker fleet: Home Assistant Voice PE pucks (5 ordered
2026-07-23) run wake word on-device and stream audio to this stack on the NAS
(`/volume1/docker/forest-voice/`, tailnet 100.89.140.98).

- `compose.yaml` — forest-ha (Home Assistant, host network, :8123),
  forest-whisper (Wyoming STT :10300, small-int8), forest-piper (Wyoming TTS
  :10200, en_US-ryan-high placeholder until a Havoc-adjacent voice is picked),
  forest-openwakeword (:10400, `hey_jarvis` placeholder until the custom
  `hey_forest` model is trained — training planned on Lynx).
- `forest_conversation/` — HA custom component (mirrored to
  `ha-config/custom_components/`): conversation entity that signs in to prod
  GoTrue as forest-speaker@aidalogistics.com (dispatcher; credentials live in
  HA config-entry storage on the NAS, not in git) and forwards utterances to
  the `trux-agent` edge function with `radio: true` for spoken-style replies;
  strips residual markdown before TTS.
- Assist pipeline "Forest" (preferred) wires whisper -> conversation.forest ->
  piper. Verified end-to-end 2026-07-23 (text -> real ops answers -> TTS mp3).

Multi-tenant note: satellites are tenant-blind; this gateway is the only
tenant-aware piece (its GoTrue login). The future SaaS shape is one gateway
service with device-token -> tenant_id provisioning.

## Wake word "Hey Forest"

Custom openWakeWord model trained on Lynx (`~/forest-wakeword/`, scripts
mirrored here as `lynx-setup.sh` / `lynx-train.sh`): 30k synthetic "hey forest"
positives (piper-sample-generator libritts_r speaker mixing), RIR + AudioSet +
FMA augmentation, ACAV100M negatives, adversarial phrases (ford/florist/forrest
gump/...). Artifact `hey_forest.tflite` lives in `oww-data/custom/` on the NAS;
`install-wakeword.sh` (scratchpad) installs + flips the pipeline. On-device
microWakeWord is a later optimization — until then pucks use "In Home
Assistant" wake word processing.

## Puck arrival runbook (per device, ~5 min)

1. Plug in; puck broadcasts setup AP -> join once from a phone, give it shop
   Wi-Fi (2.4 GHz).
2. HA auto-discovers it (ESPHome integration, mDNS) -> Settings > Devices >
   add. Name it by room: `forest-dispatch`, `forest-shop`, ...
3. On the device page: Voice assistant pipeline = **Forest**; wake word
   location = **In Home Assistant** (that's what runs hey_forest until a
   microWakeWord build exists).
4. Say "Hey Forest, which trucks are running late?" — reply should be spoken
   ops data. If mic sensitivity is off in shop noise, tune the puck's noise
   suppression + auto-gain in its ESPHome settings.
5. ESPHome dashboard for fleet config/OTA: http://100.89.140.98:6052

Fleet: 5 pucks ordered 2026-07-23. Second form factor (Forest Screens =
Flutter kiosk tablets) tracked separately — not part of this stack.

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

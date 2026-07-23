---
name: ""
metadata: 
  node_type: memory
  originSessionId: 5000f4c3-637a-49c7-8f1a-514392bdef3c
---

Owner is building a "Hey Forest" smart-speaker/display fleet for the office+shop (and eventually as a multi-tenant Truxon product).

**Hardware decision (2026-07-23):** 5× Home Assistant Voice Preview Edition ordered (~$59 each, official US sellers; AliExpress was scalper-priced $65–113 — checked). Micro Center Westmont carries NONE of the satellite hardware (no Voice PE / ESP32-S3-BOX / ReSpeaker / conference speakerphones) — verified in-store stock via site (storeid=025). Rejected: Pi-based satellites (SD cards, 10× Linux maintenance — owner explicitly refuses SD cards), Hiwonder ESP32-S3 AI kit (no ESPHome support, unknown AEC, only 2 in stock), Echo Show (locked bootloader, no custom wake word, routes data through Amazon).

**Architecture:** dumb satellites + central brain. Voice PE pucks run only wake word (microWakeWord "Hey Forest") + audio streaming; one gateway container stack on the NAS does STT (whisper/sherpa) + TTS (Piper already on NAS; ElevenLabs Havoc via trux-tts when latency allows) + conversation bridge to trux-agent. Satellites are tenant-blind (server URL only) → multi-tenant later = Truxon voice-gateway service with device-token→tenant_id provisioning (same pattern as driver tablets).

**Forest Screens (second form factor):** Android tablets in kiosk mode running the existing Flutter app (sherpa STT + Piper TTS + store-and-forward already in it) + always-on wake word + ambient ops dashboard. Verify on the Pixel-Tablet AVD per [[android-emulator]] loop before real hardware.

**Build order:** (1) "Hey Forest" wake-word model — openWakeWord server-side first (fast), microWakeWord on-device later (train on [[gpu-box]] Lynx); (2) NAS gateway containers (Home Assistant + wyoming-whisper + wyoming-piper + wyoming-openwakeword + custom forest conversation agent → trux-agent); (3) flash/adopt pucks on arrival, ESPHome dashboard for fleet OTA.

Related: [[nas-access]], [[nas-local-llm]], [[project-truxon]], [[offline-voice]], [[one-app-radio]].

---
name: offline-voice
description: "Dead-zone voice for drivers — on-device sherpa-onnx STT + Piper TTS + offline intent brain with store-and-forward queue; models served from the NAS Funnel /models path. BUILT + verified; fleet OTA publish awaits owner."
metadata:
  type: project
---

**Offline voice (task #105) SHIPPED 2026-07-23** — the companion app keeps working in coverage dead zones. Built on **sherpa_onnx** (one package: streaming **zipformer-20M** STT + **Piper VITS en_US-amy-low** TTS), NOT the original Vosk+Piper pairing — sherpa does both with one native lib.

**Architecture** (mobile/lib/services/):
- `offline_voice.dart` — model manager + engines. Packs (105 MB: stt-en-20m.zip 38 MB, tts-piper-amy-low.zip 67 MB) download once over WiFi from **`https://aida-nas.tail2c5ca.ts.net/models/`** (nginx `truxon-model-server` on NAS 127.0.0.1:8003, funnel path `/models` — Valhalla keeps `/`), **sha256-pinned in code**, atomic `.part`→rename unpack. Mic: `record` PCM16@16k → Float32 → OnlineRecognizer with endpointing. TTS: Piper → Int16 PCM → `flutter_pcm_sound`.
- `offline_brain.dart` — no-LLM intent matcher: status phrases ("we're empty" → delivered) queue `driver_change_load_status` against the cached active load; "where am I headed" reads the load cache; EVERYTHING unrecognized is saved verbatim as a note → replayed to the online Forest — never a dead end. Queue in shared_preferences, drains on connectivity return.
- `trux_voice.dart` — routes whole turns on-device when `connectivity_plus` says offline; cloud-brain failure mid-turn degrades to the offline brain; WiFi triggers model fetch; loads_screen caches loads on every fetch.

**Verification:** engine probe test (`test/offline_voice_engines_test.dart`, tag `models`, gated on `TRUXON_VOICE_MODELS` env; needs `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.4/linux/x64` on the dev box) transcribed the reference WAV and generated real Piper audio **with the exact shipped model files + config**. 83 mobile tests green; emulator smoke: app boots, logcat clean of native errors.

**APK size gotcha:** sherpa ships ~25 MB native libs PER ABI → universal release hit **170 MB**. `ndk.abiFilters` is IGNORED by the Flutter gradle plugin for plugin-AAR jniLibs (and conflicts with splits). The honored mechanism: **`--split-per-abi`** (+ `--target-platform android-arm64`) in build-apk.sh, which normalizes `app-arm64-v8a-release.apk` → `app-release.apk` for the OTA path. Result **63.7 MB**. Debug builds stay universal for the x86_64 `truxtab` emulator.

**⚠ PENDING — owner decision:** fleet OTA publish of the new APK (v1.0.0+14 when bumped). Standard: field smoke test on one device first. Related: [[android-emulator]], [[one-app-radio]], [[nas-access]].

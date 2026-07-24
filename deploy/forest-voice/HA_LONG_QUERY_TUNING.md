# Forest (HA Voice PE) — stop long queries from timing out

Symptom: "Hey Forest" cuts off on long queries — both **listening** (a long/paused
question gets truncated) and **speaking** (a long reply stops early).

The agent call itself is generous (`conversation.py` → trux-agent, 120s), and
radio-mode replies are already short (1–3 sentences), so the cutoffs are in the
**Assist pipeline / satellite**, tuned in the HA UI (not in this repo). Levers:

## Listening cut off (the main one) — end-of-speech / VAD
The Voice PE puck decides you've *finished speaking* from a silence window. Too
short → a mid-thought pause ends the command. Two places to relax it:

1. **The puck (ESPHome)** — dashboard at http://100.89.140.98:6052 → open the
   Voice PE device → its `voice_assistant:` / VAD settings. Increase the silence
   / "finished speaking" window (e.g. from ~0.5s toward ~1.5–2s). On newer Voice
   PE firmware this is exposed on the device page in HA as **"End of speech
   sensitivity"** (or similar) — set it to the most **relaxed** option.
2. **The Assist pipeline** — Settings → Voice assistants → **Forest** → STT
   (forest-whisper). Whisper itself has no hard cap; if your HA version exposes a
   per-pipeline silence/timeout there, raise it too.

## Speaking cut off — long reply stops early
Piper (forest-piper) has no Android-style length cap, so a short radio reply
won't truncate. If a *longer* reply ever stops early:
- Confirm the reply is actually short (radio mode → 1–3 sentences). If replies
  are coming back long, the pipeline isn't sending `radio:true` — but
  `conversation.py` already does, so this should be fine.
- Check the satellite/pipeline **response/playback timeout** in the pipeline
  settings; raise if present.

## After tuning
Say a deliberately long, paused question: *"Hey Forest… which trucks… are running
late… and what's the detention on the TQL docks this week?"* — it should capture
the whole thing and answer without cutting out. If listening still clips, relax
the VAD one more step.

## Related: the tablet/phone app
The mobile Forest was fixed in code (commit `07f38b5`): listen window 30s→120s,
pause 3s→5s, and long replies chunked so on-device TTS speaks them in full.

# Tablet field test — the release gate (2026-07-21)

One tablet, ~15 minutes. Green across all seven retires Mumla + Tailscale
from provisioning and makes new tablets install-one-app-and-go.

**First: publish the release** (on the release machine):
```
cd mobile && ./publish-release.sh "radio + forest + scanner + dvir + map + weather + nps"
```
The tablet self-updates OTA (or install the APK from the release page once).
This build is the first full compile with the Opus native libraries — if
gradle fails, paste the error to Forest's chat.

## The seven checks

1. **Radio — talk out.** Radio tab → hold the big button, say something.
   On truxon.com → 📻 Radio (Chrome), your name lights up and audio plays.
2. **Radio — talk in.** From truxon.com hold HOLD-TO-TALK and answer.
   The tablet plays it; the web user shows in the tablet's roster.
3. **Ask Forest.** Hold 🌲 ASK FOREST, ask "what are my loads today?",
   release. Within ~10s Forest's British voice answers ON THE RADIO —
   both the tablet and the web console hear it.
4. **Scan a POD.** Any load → 📷 → pick POD → the scanner should
   edge-detect and deskew the page. Then on the web: the document appears
   on the load, and its text landed (Forest can quote it).
5. **DVIR.** Loads tab → "Pre-trip inspection" → flag one item as DEFECT →
   submit. Web → Maintenance: an unplanned needs-review item exists,
   source dvir.
6. **Map.** Any active load → Navigate: the truck, the stop, the line
   between (straight-line label expected until Valhalla is up), ⛽ truck
   stops on the map, toggle in the app bar.
7. **Alarm check** (rolled in from the old runbook §B): from the web,
   assign a load to this tablet's driver — the urgent push should ring
   through the locked screen.

## Score card

| # | Check | Pass? | Notes |
|---|---|---|---|
| 1 | Radio out | | |
| 2 | Radio in | | |
| 3 | Ask Forest | | |
| 4 | POD scan + OCR | | |
| 5 | DVIR → maintenance | | |
| 6 | Map + POIs | | |
| 7 | Locked-screen alarm | | |

**On full green:** delete Mumla + Tailscale from this tablet, strike steps
1–2 from tablet-provisioning.md, and provision every future tablet as:
install Trux Companion → log in → grant permissions → done.

**On any red:** paste what happened into Forest's chat — exact symptom,
which check, what the screen showed.

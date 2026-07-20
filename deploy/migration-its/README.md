# ITS Dispatch delta capture (assisted)

Captures loads booked in ITS after the bulk import, into a local staging file,
so the cutover import misses nothing. It **never writes to Truxon prod** — the
cutover is a single, reviewed `import.mjs` run.

## ⚠ Why "assisted", not a nightly cron

ITS's login page is behind **Cloudflare Turnstile** bot-detection. A headless
(or even headed) automated browser cannot clear it — and defeating bot-detection
is not something we do. So an **unattended nightly login is impossible**. The
NAS cron that would have done this is **disabled** (see the scheduler
`entrypoint.sh` note); the deployed `fetch-its.mjs` + `its.env` on the NAS are
left only as reference.

The data endpoints themselves are *not* gated — once a **real, logged-in
browser** holds the session, the fetches work perfectly (proven: full board,
12 loads, 0 parse warnings). So capture runs **through the live browser**:

```
You have ITS open + logged in (real browser, past Cloudflare)
  → run the harvester (ITS_EXTRACTION.md §3) in the tab  → array of load objects
  → node merge-its.mjs captured.json                     → its_loads_full.json (+ dated snapshot)
  ── nothing leaves for prod ──
At cutover (~Aug 1):
  → alias truck 003→03, then  node import.mjs <admin> <pw>   (idempotent)
```

Low volume (a few new loads/day) means capturing every few days — plus one full
sweep at cutover — covers the whole delta. The only thing to beat is a load that
gets created *and* invoiced-then-archived (leaving the board) between captures;
periodic capture keeps that window small.

## The capture procedure

1. Open ITS in a real browser and sign in (clears Cloudflare as a human).
2. Run the harvester JS from `ITS_EXTRACTION.md` §3 in that tab. It enumerates
   the open + closed boards and parses each load → a JSON array. Save it to
   `captured.json`.
3. Fold it into staging:
   ```bash
   node merge-its.mjs captured.json      # dedups by ITS editId, writes a dated snapshot
   ```
   `its_loads_full.json` accumulates; re-running any time is safe.

(When working with the Claude Code agent, steps 1–3 are what it does for you when
you say the ITS tab is open — it harvests through the live tab and merges.)

## Cutover import

```bash
# prereq: alias truck 003 → 03 (AtoB name) or it punchlists
node import.mjs <admin_email> <admin_password>        # idempotent; skips load_numbers already in prod
# review punchlist.json
```

## Files

- `ITS_EXTRACTION.md` — reverse-engineered endpoints, field map, the §3 harvester.
- `fetch-its.mjs` — headless Playwright harvester. **Login blocked by Cloudflare**
  (kept for the parser/enumeration reference + possible CDP-attach future).
- `merge-its.mjs` — folds an assisted capture into `its_loads_full.json`.
- `import.mjs` — the idempotent cutover importer (unchanged from the bulk import).
- `its_loads_full.json` / `its_delta/` — accumulated staging + dated snapshots
  (git-ignored; contain real load data).

## Status

- **Extraction + parser:** cracked & validated live (loads 1136, 1162; full board
  harvest 12 loads / 0 warnings).
- **Unattended cron:** not viable — Cloudflare Turnstile. Disabled on the NAS.
- **Assisted capture + cutover import:** the working path.

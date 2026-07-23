---
name: project-truxon
description: Truxon TMS — live production system at ~/src/truxon; pushing main deploys prod
metadata: 
  node_type: memory
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

Truxon is a live production TMS for Aida Logistics LLC (trucking), repo at `~/src/truxon` (GitHub `turkyildiz/truxon`, private). Supabase-native (prod ref okoeeyxxvzypjiumraxq, us-east-2), frontend on Vercel at truxon.com, Flutter driver app OTA'd from GitHub releases (`turkyildiz/truxon-releases`), nightly backups pulled to a UGREEN NAS.

**Go-live: Aug 1, 2026.** Until then Truxon is NOT in real use — all prod data is test data, so prod pushes (`db push` + `git push main`) are low-risk and Ilker ships freely. On/after Aug 1 it's a real live system: revert to careful deploys (verify locally, deploy deliberately, no destructive ops without confirming).

**Why:** Pushing to `main` auto-deploys the frontend to production via Vercel; `supabase db push` applies migrations to the prod database.

**How to apply:** Still get Ilker's go-ahead before deploying, but pre-go-live a "ship it" is routine. Note: the harness classifier has intermittently blocked `supabase db push` — if blocked, hand Ilker the exact commands. Local dev: `supabase start` + `supabase db reset` is the documented local-only workflow (safe). Migrations are forward-only — never edit an applied one. Frontend uses generated types in `frontend/src/database.types.ts` — regenerate with `supabase gen types typescript --local` after schema changes. See [[user-ilker]].

**PERSONA RENAMED 2026-07-20: the AI assistant is now "Forest" 🌲** (was "Trux" — team kept colliding with the word "trucks"). User-facing name only: UI, mobile (all languages), agent system prompts, email signatures, briefs all say Forest; route /forest (with /trux redirect). Internal identifiers deliberately unchanged (tables trux_*, edge fns trux-agent/-inbox/-sentinel/-tts, nav key 'trux', localStorage). trux@truxon.com mailbox unchanged. Commit f7cf5fc. When speaking to the user or writing user-visible copy, ALWAYS call the assistant Forest, never Trux.

**FOREST'S VOICE = "Havoc" (2026-07-20, team pick):** ElevenLabs library voice `dtVZnErhiiosqofxDzSH` ("Havoc – Gritty Deep Southern Narrator"), added to the workspace + set as `DEFAULT_VOICE` in `trux-tts`. Warm/southern/gritty character (NOT a clone of any real person — a licensed library voice). `trux-tts` now has admin/cron modes `voice_search`/`voices`/`voice_add` to browse the ElevenLabs library server-side and swap voices in seconds. Persona voice is American (was British/JARVIS); web + mobile fallbacks prefer en-US male. Commit ff8e5bf.

**MAILBOX = forest@truxon.com (2026-07-20):** Boss DELETED trux@truxon.com and created a fresh forest@truxon.com mailbox. `TRUX_MAILBOX` default in `_shared/msgraph.ts` → forest@truxon.com + prod secret `TRUX_MAILBOX=forest@truxon.com` set. All mail paths (trux-inbox staff door, invoice-send, watchdog reminders, Forest replies/briefs) now read+send from forest@. Verified via trux-inbox poll (Graph reached the box cleanly). Old trux@ mail history is GONE (deleted, not renamed). Still TODO: scope the Graph app with an Application Access Policy to trux/forest+dispatch mailboxes (see [[trux-dispatch-shadow]] — tenant-wide Mail.Read is why the new box worked with no consent).

**R9 deadline (set 2026-07-23):** owner directive — "clean the table for Aug 1. finish this list, so we have time for appropriate testing." Plan: build sections (A/D/E/G/H/I/J/K/L/M) through ~Jul 27, then section N testing + O perf Jul 28–30, #200 closeout + full regression Jul 31. Testing time is protected, not squeezed.

**Sentinel lineage note (2026-07-23):** the gate-idiom audit session redefined sentinel_scan in `20260723001001_positive_role_gates.sql` — that file is the new lineage head for future sentinel splices (not 20260722051001).

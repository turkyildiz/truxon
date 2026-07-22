---
name: tolls-prepass
description: PrePass toll transactions flow into Truxon via SFTP → NAS importer → toll_transactions; LIVE since 2026-07-21
metadata:
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

**LIVE 2026-07-21.** PrePass delivers toll CSVs over **SFTP** (`files.prepass.com:22`, username `573890`), NOT the API — the credentials arrive as TWO emails (username in one, password in a separate "for security" email; don't expect one account per email). Creds in `/volume1/docker/truxon-tolls/prepass_sftp.json` (chmod 600) + `tolls.env` (SUPABASE_URL/ANON_KEY, TOLL_SYNC_KEY).

Flow: **NAS `fetch-tolls.py`** (python:3.11-slim + paramiko container, scheduler cron **05:30 local daily**, `run-tolls.sh` flock+logs) pulls NEW csv (tracked in state.json), maps PrePass columns → the existing **`import_toll_transactions(p_rows)`** RPC via **toll-sync edge fn `mode:'import_rows'`** (gated by `X-Toll-Key: TOLL_SYNC_KEY`; service key stays server-side). RPC dedups on `toll_id` (synthesized sha256 of CustID+PPTagID+agency+exitplaza+date+time+amount — CSV has no native id) and matches trucks on **`EquipID` == trucks.unit_number**. Repo: `deploy/tolls/`.

CSV columns: PostingDate, InvoiceDate, CustID, Source, ReadType, PPTagID(device), ETagID_Plate, **EquipID(unit#)**, Agency, Entry/Exit_Plaza/Date/Time, Toll_Class, Miles, Toll_Amount. Agency→state map in the script (ILTOLL→IL, NTTA/HCTRA→TX, OTA→OK, BATA→CA, …); extend when a new agency shows `state=''`.

First import: **42 tolls, $383.01, 8 trucks (units 09/10/11/12/13/14/15/16), 0 unmatched.** Forest already knows `toll_by_truck` / `toll_by_agency`; Tolls page live. The old API-pull path (PREPASS_CLIENT_ID/SECRET/ACCOUNT_NUMBERS + cron) stays in toll-sync but is unused — this account is SFTP-only. Related: mirrors the [[nas-access]] fuel-fetcher container pattern.

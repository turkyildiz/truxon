---
title: Sessions Index
tags: [moc, sessions]
---

# 🗒️ Sessions

A durable, readable log of our working sessions — what we did, decided, and shipped. These notes are **committed** (small, secret-free, GitHub-backed). The raw transcripts are archived **locally** in `Sessions/raw/` (gzipped, gitignored — they're large and can contain fetched keys; see [[obsidian-vault]]).

## How sessions are saved
1. `vault/save-session.sh [id]` — gzips the raw JSONL into `Sessions/raw/` (local ground-truth, off GitHub) and secret-scans it.
2. Write/append a readable log note here (one per session).
3. `vault/save.sh` — commits + pushes the readable logs.

_At each closeout this is part of the deliverable ([[working-agreement]] → Memory & Sessions)._

## Log
- [[2026-07-21_truxon-build-marathon]] — the big continuous run: pre-launch security stack (honeypots, ransomware guards) → the **48-hour plan** → **R5 / R6 / R7** playbook + sentinel expansion → set up this **Obsidian vault as living memory** → installed Obsidian → wrote [[Truxon]] → session-saving. ~29 prod commits, playbook 129→171/1000. Raw: `raw/a28d9126-….jsonl.gz`.

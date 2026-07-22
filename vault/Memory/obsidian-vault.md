---
name: obsidian-vault
description: "The Obsidian vault is the durable home for memory + rules + reports; ~/.claude memory is a symlink into it (repo-backed)"
metadata:
  type: reference
---

The owner set up an **Obsidian vault** as the permanent home for all knowledge so nothing is ever lost (2026-07-22). It lives **inside the repo** at `~/src/truxon/vault/` and rides the repo's GitHub backup.

**Live-memory plumbing:** `~/.claude/projects/-home-ilker-DEV/memory` is a **symlink** → `~/src/truxon/vault/Memory`. So this memory folder IS the vault; every memory write lands there and is version-controlled on the next commit. Don't recreate the memory dir as a real folder — if it's ever missing, re-link: `ln -s /home/ilker/src/truxon/vault/Memory /home/ilker/.claude/projects/-home-ilker-DEV/memory`.

**Vault layout:** `Home.md` (MOC) · `Memory/` (this, source of truth) · `Rules/` ([[working-agreement]], [[engineering-conventions]]) · `Reports/` (accountability snapshots) · `Reference/` (pointers into the code repo) · `.obsidian/` (config committed; `workspace*.json`/caches gitignored via `vault/.gitignore`).

**Rules notes are the durable behavior record:** `Rules/working-agreement.md` = how Claude + owner work (autonomy, push=prod, verification discipline, honesty, secrets); `Rules/engineering-conventions.md` = the patterns/gotchas (sentinel splice, pgcrypto qualification, trux_insights category/entity constraints, stable-fn no-temp-table, local-vs-prod grants, exam harness, emulator loop). Keep these current as new conventions emerge. Obsidian app isn't installed on the box yet — everything is plain Markdown, readable anywhere. Related: [[finish-before-next]], [[project-truxon]].

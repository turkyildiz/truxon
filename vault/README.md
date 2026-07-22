---
title: README
tags: [meta]
---

# Truxon Vault — how this is wired

This is an **Obsidian vault** that is the durable home for Claude's memory, our working rules, engineering conventions, and the accountability trail. It lives inside the Truxon git repo (`~/src/truxon/vault/`) so it rides the same **GitHub backup** as the code — commit + push and it's off-box.

Start at [[Home]].

## The live-memory plumbing (important)
Claude Code keeps its cross-session memory at:

```
~/.claude/projects/-home-ilker-DEV/memory/
```

That path is now a **symlink** to this vault's `Memory/` folder:

```
~/.claude/projects/-home-ilker-DEV/memory  →  ~/src/truxon/vault/Memory
```

So **every memory note Claude writes lands in this vault automatically** — and gets version-controlled the next time the repo is committed. `Memory/MEMORY.md` is the index Claude auto-loads each session; the other notes are one-fact-per-file with YAML frontmatter and `[[wikilinks]]`.

**If you ever move the repo:** re-point the symlink:
```bash
rm ~/.claude/projects/-home-ilker-DEV/memory
ln -s /NEW/path/to/truxon/vault/Memory ~/.claude/projects/-home-ilker-DEV/memory
```

## Open it in Obsidian
Obsidian isn't installed on this box yet. To use it:
1. Install Obsidian (AppImage / flatpak `md.obsidian.Obsidian` / .deb).
2. **Open folder as vault** → select `~/src/truxon/vault`.
3. The graph, backlinks, and `[[links]]` work immediately (config is in `.obsidian/`).

You can also just read/edit every note as plain Markdown in any editor — nothing here depends on Obsidian.

## Structure
- `Memory/` — Claude's live memory (the symlink target). **Source of truth.**
- `Rules/` — [[working-agreement]] (how we work) + [[engineering-conventions]] (patterns & gotchas).
- `Reports/` — accountability snapshots (also in `docs/`).
- `Reference/` — [[reference-index]]: pointers into the code repo (not duplicated).
- `.obsidian/` — vault config (committed). Per-machine UI state (`workspace*.json`, caches) is gitignored.

## Back it up
It's already versioned in git. To get it off-box, `git push` (goes to GitHub with the repo). Nothing secret is stored here — credentials never go in memory/notes (see [[working-agreement]] → Secrets).

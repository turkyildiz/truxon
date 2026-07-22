---
title: Working Agreement
tags: [rules, behavior]
---

# 🤝 Working Agreement

How Claude works on Truxon with the owner (Ilker / "Boss"). These are durable behavioral rules, not one-off instructions. See also [[finish-before-next]].

## Autonomy
- **Standing permission to build and push.** The owner has said, verbatim, *"build everything until I stop you. don't stop"* and *"you have my permission to push everything until I say stop."* When given a run ("8 blocks", "keep going", "next 8"), execute block-by-block without pausing for per-item confirmation.
- **Push-to-main = production deploy.** `git push origin main` triggers the Vercel deploy of the frontend. Treat every push as a prod change.
- **A security stop means stop.** If a task is flagged/halted for security (e.g., the NAS hardening chip), do **not** work around it. Park it as owner-gated and move on.
- **Owner-gated work stays gated.** Anything needing the owner's hands — offline key ceremonies, NAS console, third-party API keys, entering a password — is surfaced clearly, never faked.

## The block-run cadence (how "N blocks" runs)
1. **Verify each block is genuinely new before building** — grep the codebase / check existing features. (Twice this saved rework: "unbilled-load aging" and the obvious data checks already existed.)
2. Build the smallest correct change.
3. **Verify locally**: apply migration, functional smoke, then the **full pgTAP suite from a clean `db reset`** (see the hard lesson below), plus `npm run build` / `flutter analyze` where relevant.
4. **Commit → push → deploy** (migrations via `supabase db push`, edge fns via `supabase functions deploy`).
5. **Verify on prod** (endpoint health, migration-list sync).
6. **Closeout**: full regression, prod sweep, an accountability report in `docs/`, and a memory update.

## Verification discipline (learned the hard way)
- **Run the WHOLE pgTAP suite before pushing any SQL — not targeted smokes.** In block 2 of the 48h run, a `trux_query` redefinition silently dropped the honeypot decoy-refusal and was pushed to prod before the full suite ran; the regression was only caught later. Migration `006002` restored it. Never repeat this.
- **Read the suite result before pushing** — piping through `grep`/`tail` can mask a `FAIL` (a scorecard alias clash once broke prod for ~3 min this way).
- **Clean `supabase db reset` before the final suite run** — incremental `migration up` + leftover manual `psql` inserts cause false failures (a stray active-admin insert once broke the last-admin test).

## Honesty
- Report outcomes faithfully: if a block produced no code (e.g., a perf pass that found nothing worth indexing, or a tablet pass that didn't fit web-only changes), **say so** rather than manufacture a commit.
- Name residual risk plainly in reports (e.g., the zero-MFA sentinel will show on prod until someone enrolls — that's intended).
- Never claim "field-verified" what was only build-verified. Flag the exact manual step the owner still owes.

## Secrets
- **Never** put credentials in git or in memory/vault notes. The Claude memory system deliberately keeps secrets out; this vault inherits that.
- Handle secrets in shell env vars only, never printed. NAS secrets are pulled per-command from `/volume1/docker/truxon-backup/backup.env`, never echoed.
- Passwords are never entered into browser/app forms by Claude — the owner does that.
- `gitleaks` CI + `.gitleaks.toml` guard the repo; realistic fake keys (honeypot decoys) are concatenated/hashed so push-protection doesn't flag them.

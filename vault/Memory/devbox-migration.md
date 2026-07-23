---
name: devbox-migration
description: Laptop swaps are a scripted ~30-min routine — deploy/devbox/ kit; STANDING RULE to keep it updated in the same commit as any setup change
metadata:
  type: feedback
---

Owner directive (2026-07-23, after the ike→lynxdev swap took hours of archaeology): "we need to do a better job — I should be able to change laptops without much issues… and keep it up to date."

**Why:** the swap surfaced every durability gap at once — memory symlink, toolchain, signing keystore path, google-services.json, the R9 block list living only in an old transcript. Prod was never at risk, but a day was lost.

**How to apply:** the migration kit lives at `deploy/devbox/` — `bootstrap-sudo.sh` (root half), `bootstrap.sh` (idempotent user-space toolchain + Claude-memory symlink + AVD + app deps), `restore-signing.sh` (NAS keystore restore w/ cert verify), `MIGRATION.md` (recovery map, ordered steps, known snags, decommission checklist). **STANDING RULE: any change to dev-box setup — new tool, new secret location, new manual step, changed path — updates `deploy/devbox/` in the SAME commit.** Nothing durable may live only on one box: distilled artifacts → vault (committed); big/raw (transcripts) → NAS `devbox-archive/`; secret values → KeePassXC ([[secrets-vault]]). See [[user-ilker]], [[disaster-recovery]].

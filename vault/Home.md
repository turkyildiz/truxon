---
title: Home
tags: [moc]
---

# 🏠 Truxon Vault — Home

The durable home for everything we've built and agreed: Claude's memory, the working rules, engineering conventions, and the accountability trail. Version-controlled inside the Truxon repo, so it rides the same GitHub backup as the code and is never lost.

> **Live memory:** the `Memory/` folder IS Claude Code's memory (`~/.claude/projects/-home-ilker-DEV/memory` is a symlink here). Every session's memory write lands in this vault automatically. See [[README]] for how the plumbing works.

## 🧭 Start here
- [[working-agreement]] — how Claude and the owner work together (autonomy, push discipline, verification, honesty)
- [[engineering-conventions]] — the technical patterns & gotchas that keep changes safe
- [[Memory/MEMORY|Memory index]] — the auto-loaded index of every memory note
- [[reports-index]] — the accountability trail (what shipped, when, verified how)
- [[reference-index]] — pointers into the code repo & key paths

## 🗂️ Memory notes by theme
**Who / how we work**
- [[user-ilker]] · [[finish-before-next]] · [[week-standard]] · [[android-emulator]]

**Product & platform**
- [[project-truxon]] · [[northstar-project]] · [[csuite-playbook]] · [[one-app-radio]]

**Security**
- [[security-posture]] · [[nas-access]]

**Integrations & data**
- [[qbo-integration]] · [[eld-drivehos]] · [[geocoding]] · [[tolls-prepass]] · [[prepass-toll-api]] · [[nas-local-llm]] · [[its-migration]]

**Operations / features**
- [[customer-enrichment]] · [[trux-dispatch-shadow]] · [[wo-email-intake]] · [[fuel-theft-detection]] · [[factoring-ar]]

## 📌 Standing owner action items (from the reports)
1. **M-4 OTA manifest signing** — needs an offline keypair ceremony
2. **NAS hardening** — B2 Object Lock + move secrets off inline compose (parked; needs NAS console)
3. **MFA + M-3 smoke** — enroll one TOTP factor; confirm mobile session survives a sideload restart
4. **ELD DriveHOS key** (Aida's) and **Denim factoring key** — both unblock live features
5. **Vision rate-con scan** — one pending click to finish customer enrichment

_Full, current list lives in the latest report under [[reports-index]]._

---
name: dr-readiness-roadmap
description: "Action plan to take DR + cyber-event recovery readiness from 84 → 100, centered on an automated weekly watchdog drill"
metadata: 
  node_type: memory
  type: project
  originSessionId: 7541d708-7353-4f10-878c-db1e3485f192
---

DR / cyber-security-event **recovery readiness roadmap**, written 2026-07-23 after a live drill (see [[disaster-recovery]] for drill results). **Current score: 84/100 (B+).** For developers: this is the plan to reach — and *stay at* — 100.

**What "100%" means (measurable, not aspirational):** every recovery path is TESTED on a schedule, every failure ALARMS within hours, one full end-to-end failover has been drilled with a MEASURED RTO/RPO, and the residual cyber items are closed — sustained because the tests run themselves. The 84 exists because the drill found a recovery leg ([[offsite-nas]] rsync) that had silently died with **no alarm**; the whole plan hardens against that class of failure.

**Workstream 1 — the Weekly Watchdog Drill (the spine; Claude builds).** New `dr-drill.sh` on the NAS scheduler, Sunday 05:00 (after `restore_test.sh`), posts ONE structured report → `watchdog` edge fn → `trux_insights`. Watchdog raises a critical on any red check **OR on a missing drill heartbeat** (a skipped drill is itself the alarm — this closes the silent-failure gap). Six checks:
1. **Restore drill** (exists) — decrypt newest `db_*.dump.gpg` → throwaway Postgres; assert core tables have rows (~11 profiles / 984 loads / 232 customers / 2498 docs / 10861 storage objects).
2. **Backup freshness, all 5 copies** — Supabase `db-backups` bucket, NAS-local, Backblaze B2, INDIANCREEK offsite, `dr-vault` signing — each < 26 h.
3. **Signing-key recoverability** — decrypt all 3 copies (dev/NAS/`dr-vault`), assert `sha256` == live keystore (`4541d893…`).
4. **Security posture** — call `security_console` + `security_audit_verify`; assert audit hash-chain intact, `guard_armed`, lockdown off, baseline not drifted.
5. **Guard live-fire IN THE SANDBOX** — against the throwaway restore DB from check 1 (NEVER prod — prod guards page via OOB dblink on rollback), attempt DROP / TRUNCATE / bulk-DELETE and assert each is BLOCKED. Proves guards *block*, weekly, with zero prod risk.
6. **Honeytoken/canary liveness** — non-tripping probe that the fire path is still wired.

**Workstream 2 — close detection gaps (the 84's root cause; Claude).** Wire `offsite_fresh` (didn't raise a finding during the ~28 h outage — verify it's connected end-to-end) + a new `drill_fresh` watchdog check to actually write `trux_insights`. Per-leg heartbeats so one broken copy is visible, not masked by "some copy is fresh."

**Workstream 3 — shrink RPO 24 h → ≤ 15 min (owner billing).** Enable **Supabase PITR/WAL** so a bad event costs minutes, not a day. Biggest single DR-quality lever. Nightly custom dump stays as the offsite/immutable layer.

**Workstream 4 — measure RTO (joint game-day).** Documented, time-boxed drill: rebuild from backups into a SCRATCH Supabase project, restore DB, re-provision secrets from the KeePassXC [[secrets-vault]], re-point config, re-sign a tablet build — with a stopwatch. Restore ≠ business recovery. Record RTO, write the runbook, repeat quarterly.

**Workstream 5 — close cyber residuals (owner-gated).** Enforce **MFA/AAL2** for admin+office (currently dark-launched opt-in, see [[security-posture]]); **sign the OTA manifest** (open finding M-4 — offline key, public key baked in app); NAS hardening from `docs/THREAT_JADEPUFFER.md` (secrets → root-600 `env_file` not inline compose, firewall media stack off the backup vault, run `deploy/security/ioc-block.sh`, confirm B2 Object Lock); **delete the stray unencrypted `signing-2026-07-21b.tar.gz`** next to the `.gpg` on the NAS.

**Score math:** WS1 +6, WS2 +3, WS3 +3, WS4 +2, WS5 +2 → **84 → 100.** WS1+WS2 alone (Claude, this week) ≈ +9 → ~93.

**Sequence:** (1) this week — Claude builds WS1 harness + WS2 alarms + tarball cleanup (first automated drill runs the coming Sunday); (2) owner approves PITR (billing) + MFA enforcement → Claude implements; (3) within 2 weeks — joint failover game-day, record RTO, write runbook; (4) ongoing — the weekly drill pins the number and pages on any regression.

**Why:** the failure mode that caps readiness is "recovery capability you believe you have but don't" — proven live 2026-07-23. Only scheduled, self-alarming tests prevent it recurring.
**How to apply:** start with Workstream 1 (`dr-drill.sh` + watchdog wiring, mirror `restore_test.sh`/scheduler patterns in [[nas-access]]); everything downstream assumes the weekly drill exists. Related: [[disaster-recovery]], [[offsite-nas]], [[security-posture]], [[nas-access]], [[secrets-vault]].

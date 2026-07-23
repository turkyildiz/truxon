# Accountability — R9 "200 blocks" run (2026-07-22 → 23, in progress)

**Directive:** "give another 200" → "go for 200, see you tomorro." Same discipline per block: build → full pgTAP from clean reset → prod push → live verify → commit+push.

**Suite:** 797 → **845 pgTAP** (136 files) · mobile 84 → **87** · deno denim 6 → **8**. All green from clean resets, every block live-verified on prod.

## Shipped so far (running log)

### B. DOT / compliance (13–28 done; 16/17 blocked honestly)
- **#18/19 Annual inspection sentinel** — keys off formal `dot_inspection` maintenance records; 12 trucks fired critical on prod (matches audit pack's zero annuals — intended pressure).
- **#20/21/28 Driver compliance program** — `driver_compliance_events` (MVR review / drug test / alcohol test / Clearinghouse query), pool-enrollment fields on drivers, Compliance-log card on Drivers page, three warn sentinels citing 391.25 / part 382 / 382.701(b). 11 drivers × 3 warns fired live.
- **#25 DVIR radio nudge** — Forest speaks when a driver is rolling >11 mph with no pre-trip today; once/day, silent on unknown; rides the next OTA (v15).
- **#26 DVIR % on scorecards** — pre-trip days ÷ ELD driving days (>5 mi); live baseline is 0% for everyone (real) and null for Charles Sutton (ELD unlinked).
- **#27 dot_audit_pack v2** — counts formal dot_inspection (v1's ilike missed the enum!), med-card/MVR/Clearinghouse/pool/DQF coverage, honest not_tracked shrunk to 391.23 histories + CH results; in the Forest catalog + DOT Audit Readiness card on Reports.
- **#16/17 vision credential backfill** — still blocked on zero driver docs; DQF page instructs the office what to photograph.

### C. Accounting v2 (29–44 ALL done)
- **#29 Fee write-off proposals** — propose-only by construction (test locks in the invoice is never touched); 116 slivers / $17,359.09 seeded; approve/dismiss → accountant packet; QBO mirror clears them once applied.
- **#30 Denim reconciliation** — `denim_jobs` statement mirror on every 2h pull. Live payload taught us fees ride `subtype` (factoring_fee/servicing_fee under type 'earnings') — jobFee fixed; real fees now flow: **Denim $21,844 vs $18,389 captured**, 350/471 jobs matched, 0 per-invoice mismatches. Write-off seed re-anchored to the sliver class.
- **#31 Sliver-aging sentinel** — 90+ day-old fee residue nags in aggregate; live: "5 slivers ($474.21)". Two in-flight fixes: null entity_type aborted the scan (caught because a piped exit code masked a suite failure — gates now check real exit codes), and the anchor moved to invoice_date (every factored_at is backfill-dated).
- **#32 Cost of factoring** — live: **effective rate 1.99%, ~5.3% annualized against 139-day book pay speed**. Factoring is cheap money for Aida; now it's provable.
- **#33 Customer statement PDFs** — Statement button on Aging; letterhead style, aging buckets, total due.
- **#34 Statement email drafts** — mailto drafts in Collections (propose-only; office hits send).
- **#35 Rev-rec drift** — earned (delivery month) vs booked (invoice month); live data showed the gap is unlinked QBO-history invoices, not timing — card says so.
- **#36 Credit memos** — CreditMemo joined the QBO CDC pull + backfill; live: 1 memo / $8,274 since Jan, **invoice accuracy 99.64%** — playbook #72/#73 flipped live.
- **#37 Payment-application audit** — three mismatch lists; live: 0/0/0, books agree.
- **#38 Seasonal budget seeding** — month-of-year factor from prior-year GL, exactly 1.0 until a month recurs (no fake seasonality); caught GREATEST/LEAST null-skip clamping empty history to 0.75.
- **#39 Budget-variance sentinel** — cost line 20%+ over two months running.
- **#40/41 True operating ratio** — gl_cfo_snapshot carries the equipment-payment gap the GL can't see + equip-adjusted OR (live 81.9% / gap $0 until payments entered); break-even card lays out the per-mile recipe with basis label.
- **#42/43 Per-truck P&L + ROI** — each unit's own ledger; live: unit 12 leads, $120k rev / $96.6k net-before-payment (3mo); ROI blank until payments entered.
- **#44 Depreciation schedule** — owner-view straight line (60mo, 20% salvage, assumptions printed); appears when purchase data is entered.

### Earlier tonight (sections A/misc, pre-compaction)
Lynx warm-pin, vision tiling @200 DPI, LLM extraction ledger (prompt sha only), fuel-CSV fuzz (caught bad timestamps), route replay, med-card fields + credential ladders, DQF page, equipment payment/docs forms (owner's in-flight asks), AR audit sweep (DSO 14.3→9.3), offsite NAS 3-2-1 completed + verified.

## Owner-morning items
1. **OTA publish v14**: `cd ~/src/truxon/mobile && ./publish-release.sh "…"` (v15 will carry the DVIR nudge).
2. **Truck payments + purchase price/date** on Equipment forms → unlocks ROI, true OR, depreciation.
3. **Photograph CDLs + med cards** into driver 📄 Docs (DQF page shows exactly what's missing).
4. **Annual inspections**: 12 criticals live — enter paper ones as service type "DOT Inspection" or schedule.
5. **Fee write-offs**: 116 proposals ($17,359) on Invoices → Factoring; approve → hand packet to accountant.
6. **INDIANCREEK ~99% full** — prune before nightly replication grows.
7. MVR / Clearinghouse / testing-pool: 33 warns live; log events in the new Compliance log as you do them.

*(Run continues; closeout will finalize the count.)*

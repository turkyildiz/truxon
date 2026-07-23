# Accountability — R9 "200 blocks" run (2026-07-22 → Aug 1 target)

**Deadline set 2026-07-23:** table clean by Aug 1; build through ~Jul 27, testing (section N) + perf Jul 28–30, closeout Jul 31. Testing time is protected.

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
8. **Possible duplicate load entry**: loads #24/#27 look keyed twice (same broker/day/addresses/rate) — cancel one if so.
9. **Driver hire dates**: 6 of 11 active drivers have none — tenure metrics run thin until entered.
10. **TQL delivery docks**: P90 dwell 14.8h, $672 detention in 45 days — the dock-time league card is your exhibit.

### F/D. Sentinels v3 + ELD (76–84/88, 45/46, 57)
- **#76 Pickup detention** — premise was real (8 pickup events measured, 0 proposals banked); the proposer covers pickups, the imbalance was historic. Catch-up run banked 13 pickup proposals with evidence.
- **#77/78/80/81/82/84/88 sentinel batch** — stale drafts 48h+, POD-on-file-but-uninvoiced 72h+, fuel/tolls on ELD-no-mileage days, same-day duplicate loads (live: one real candidate, loads #24/#27), QBO sync drift, 30-day-unseen findings auto-close. **Precision incident:** first live scan fired 19 darkday warns that were eld_daily_miles JOB GAPS, not parked trucks — hotfixed to require banked movement on both adjacent days; all 19 auto-resolved.
- **#57 ELD gap-filler** — root cause: the miles bank skips days (156 gaps in 14d!). DriveHOS keeps history, so eld-sync's new gapfill mode re-fetches exactly the missing vehicle-days nightly, re-banks, and stamps zero-markers when the truck really sat. (Live drain in progress at handoff.)
- **#58 Dark-ELD ladder** — 'Unit 05 ELD STILL dark - week 28' live; title bumps weekly so the brief re-surfaces it, detail names the action (fix or mark out of service).
- **#60 Map breadcrumb tails** — click a truck, see its last 4h of ELD GPS (solid); phone trail stays the dashed fallback.
- **#62 IFTA close package** — 🖨️ printable per-jurisdiction miles+gallons PDF with the coverage window printed on the page.
- **#51/61 Dock-time league** — dwell avg/P50/P90 + detention $ per facility; live: TQL delivery docks P90 14.8h, $672 detention in 45 days. Bonus catch: the codebase's negated auth-gate idiom passes on a null role claim (test-context only, not API-exploitable) — new function written positive-form, idiom-wide audit chipped for a separate session.
- **Suite now 866 pgTAP / 143 files** · mobile 87 · deno 8.
- **#52/53 ETA + late-risk** — straight-line ×1.25 @ 47 mph net vs appointment, HOS-checked; Late-risk card on Dispatch (5-min refresh). Estimate labeled an estimate.
- **#54/55 Truck-day utilization** — moving vs parked days per unit from the ELD bank; live: unit 09 moved 22/24 days ($1,653/moving day), unit 14 $4,922/day. **Second live catch:** state attribution DELETES the blank-state day row — gap detection was counting every attributed day as a gap (real backlog 63, not 156) and utilization read 0 moving days; both fixed to any-state semantics.
- **#113 HOS on dispatch** — verified already live pre-R9 (hours-left on the driver picker).
- **#56 Speeding trend** — minutes at 75+ this week vs last, per truck, with delta.
- **Forest catalog sync** — all 13 of tonight's report functions in the PREFER list; trux-agent + trux-inbox redeployed.
- **Suite at checkpoint: 867 pgTAP / 144 files.**
- **#63 Breakdown-ML readiness** — live: 36 rows, 0 breakdowns observed, honestly not trainable (~10 weeks to the row bar; a healthy fleet delaying the model is fine).
- **#86 Weekly sentinel digest** — Monday 12:20 push, grouped by category with critical-first samples; live render: 154 open / 45 critical across 6 categories in one message.
- **Suite at checkpoint: 871 pgTAP / 146 files.**
- **#87 Sentinel snooze** — 😴 7d on the feed: finding stays open and truthful, but brief/digest/pushes skip it until the date passes; brief reports how many are sleeping.
- Section F is effectively complete (75 covered by the sliver-aging nag; 79 needs payroll data — honest gap; 83's pre-book guard already existed).
- **Suite at checkpoint: 874 pgTAP / 147 files.**
- **Section G start** — playbook flips 70/241/434/515/516 (accessorial capture, dispatch productivity 2.25 loads/dispatcher/working-day, invoice-dispute proxy, tenure avg/median). **Playbook now 191 live.** Tenure is thin: 6/11 drivers missing hire_date (office entry item).
- **Suite at checkpoint: 877 pgTAP / 148 files.**
- **#45/46 Harsh-driving proxy** — breadcrumbs are dense (p90 gap 10s), so ≥25 mph lost in ≤12s is banked nightly as a hard-braking proxy (labeled a proxy everywhere). Live: 77 braking + 31 acceleration events in 2 days; real samples like 45→9 mph in 10s. On the driver scorecard as 'Harsh'; playbook harsh metric flipped with an honest source note.

### Aug 1 sprint — day 1 afternoon (owner present)
- **Gate-idiom audit merged** (owner-launched session): 22 gates converted to positive form; sentinel lineage head is now `20260723001001`; migration watermark moved to 20260723 (new stamps follow it).
- **#101 complete** — doc types normalized + NAS-3B sweep: 46 relabeled (RCs/BOLs/receipts from opaque filenames), 49 honestly kept 'Other', 0 errors; 224 image-only docs queue for the vision path. Live catch: NAS model tag is `qwen2.5:3b-t8` and rag.env's OLLAMA_URL points at Lynx — classifier got its own target vars.
- **#120 Load clone** (⧉ on Loads → Dispatch prefilled, dates/driver/truck cleared) · **#121 Check-call log** (append-only 📞 timeline per load) · **#122 Shift-handoff board** on Dispatch.
- **#154 Keyboard shortcuts** (g+key nav, / search) · **#158 CSV export on every table** (one shared-component change) · **#164 print stylesheets** · **#167 monthly owner package PDF** · **#172 weekly flash v2** (pricing discipline + DOT readiness, snooze-aware).
- **Suite: 888 pgTAP / 151 files.**

*(Run continues; closeout will finalize the count.)*

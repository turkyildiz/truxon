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
- **#173 anomaly digest** (honest readiness while snapshots are young) · **#49 fuel-stop analysis** (live: TA Parowan +$195 premium/8 visits) · **#50 idle heat-map** (two live precision fixes: breadcrumb holes ≠ parked time; edited-migration trap reaffirmed — new file every time) · **#110 doc retention** (live truth: POD 38%, BOL 1%, driver docs 0%) · **#131 carrier packet generator** (pdf-lib merge of the 'Broker Packet' Drive folder) · **#107 doc-search type filter** · **#121-122 already logged** · **A#10 Machines card** (Lynx GPU heartbeat live).
- **A#12 failover drill EXECUTED**: stopped Ollama on Lynx → heartbeat flipped to 'ollama=inactive' in 24 seconds, VRAM freed; restarted, recovery confirmed; drill finding shipped — the Machines card now goes red on a sick heartbeat, not just a silent one.
- **Suite: 896 pgTAP / 155 files.**

### Mobile v15 batch (Aug-1 sprint, day 1 evening)
- **#143/144 Driver settlement** — `my_settlement` RPC (own pay itemized per load, 26-week history, revenue excluded) + My Pay screen with week chevrons; office/unlinked logins get an honest null.
- **#141 Breakdown flow** — guided report (what broke, drivable?, GPS auto-attach): unplanned MX item + critical ops insight + a driver-callable `breakdown` action on the notify fn that rings admins/dispatchers through DND. Report is on the books even if the push fails.
- **#142 Fuel receipt capture** — scan at the pump (OCR rides along), files against the TRUCK under a driver-scoped `fuel/<driver_id>/` storage prefix; catches cash buys the card import never sees.
- **#145 Document wallet** — CDL/med-card + truck registration/insurance/permits pulled from office filing; storage gate scoped to exactly the wallet set (own driver docs; truck ROAD paper only, PODs excluded). Prod truth: 0 driver docs on file until the owner adds CDL/med-card scans (already on the owner list).
- **#150 Scan compression** — 2200px q70 before upload (5-10 MB → ~½ MB), EXIF stripped, OCR still runs on the original, raw-bytes fallback.
- **#149 Diagnostics screen** — one-tap checks (version, server latency, GPS permission/service, push) + copy-paste report with the field log; wired from About.
- **#146 Push preferences** — weather/paperwork/other can be quieted; assignment + breakdown alarms can never be muted (tested).
- **#139/#140 Offline brain v2** — pickup/load-number/breakdown/detention intents; full Spanish (Spanish phrase → Spanish answer). Two real bugs caught by tests: "still waiting at the dock" would have read as *arrived* (ordering), and Dart's ASCII `\b` never matches after an accented character ("entregué" was unreachable). Honest limit: the sherpa STT model is English-trained — Spanish text handling is exact, Spanish *speech* recognition is best-effort until a bilingual model ships.
- **#147 Dark-mode audit** — theme system was already sound (ThemeMode.system + brightness-aware status colors); one real defect fixed (About-tab log panel was near-invisible in dark).
- **#148 Cab-mount mode** — persisted keep-screen-awake toggle (wakelock), re-armed on app start.
- **#151 Staged OTA rollout** — `rolloutPct` in latest.json + stable per-device buckets; `ROLLOUT=25 ./publish-release.sh "…"` ships a 25% wave, republish wider to widen; absent pct = everyone (old manifests unaffected).
- **#152 v15 release readiness** — release APK builds clean (63.9 MB); emulator visual pass done for the login surface in light + dark (no crashes in logcat). The authenticated screen walk needs the driver2 password, which by design exists only with the owner (rotated 2026-07-21, never persisted) — rotating it myself would sign out the real tablet #2, so I did not. **Owner: one emulator login (or share the test password again) + `cd ~/src/truxon/mobile && ROLLOUT=100 ./publish-release.sh "v15: settlement, breakdown, fuel receipts, wallet, diagnostics, offline v2 + Spanish"` publishes the OTA.**
- **Suite: 922 pgTAP / 162 files · mobile 99 flutter tests.** All pushed + live-verified on prod.

### Aug-1 sprint — day 2 (new dev box lynxdev; block list recovered from old-box transcript)
- **#104 Rate-con line items** — `load_line_items` (RLS office-only, posture-baselined); extraction prompt itemizes ONLY charges printed on the document (single-total rate cons yield one line_haul row — no invented breakdowns); Dispatch shows the breakdown under the Rate field and saves it on load create.
- **#105 Rate-con reconciliation** — `ratecon_recon_report()` (mismatch list ranked by |delta|, honest `not_extracted` count, fuel-surcharge capture stats for the pending G flip) + sentinel `ratecon_recon:` money-warn (>$1 drift, auto-resolves when booked rate matches the paper). Sentinel lineage head is now `20260723150003`.
- Live-verified: migrations local=remote, anon → `permission denied` on the RPC (gate holds), extract-pdf redeployed.
- **Suite: 930 pgTAP / 163 files** — one real test catch on the way: RLS assertions are no-ops as `postgres`; the driver-invisibility test needed `set local role authenticated`.
- **G flips #14/#69 (fuel-surcharge revenue + recovery rate)** — `fuel_surcharge_recovery(days)`: FSC captured from line items ÷ net-of-discount fuel spend, extraction coverage printed in the payload (never implied 100%). **Playbook now 193 live.** Suite: **932 pgTAP**. Prod pushed, anon gate verified.
- **#106 BOL↔POD pairing** — `doc_pairing_report(days)`: delivered loads with a broken road-paper pair, named worklist worst-first, role-gated. Suite 937.
- **#102 Misfiled-doc detector** — NAS 3B re-reads LABELED docs weekly (Sun 05:10 scheduler cron, run-audit.sh): opinions banked in `doc_label_audits` (propose-only; unsure = 'Other' and never disputes a human), disagreements fire sentinel `doc_misfiled` ops-warns that auto-resolve on relabel. Sentinel lineage head → `20260723150007`.
- **#103 OCR quality** — `doc_ocr_quality_report()`: garbled/thin/no_text verdicts from indexed text (plain heuristic, no LLM), re-scan worklist worst-first, image-only docs routed to the vision queue not the re-scan list. Suite: **945 pgTAP / 165 files.** All prod-pushed + live-verified; first live audit run fired on the NAS.

- **#109 index-freshness sentinel** — docs waiting 3h+ with a 26h-silent indexer fires ops-warn (the CRON_SECRET-lockout class of failure, caught in hours not days); lineage head `20260723150009`.
- **#108 more-like-this** — `similar_documents(id)` pgvector RPC + expander on DocSearch results (real catch: this pgvector build has no `avg(vector)` — first-chunk representative; `<=>` needs `extensions` on the search_path).
- **#111/#112 bulk zip + storage dashboard** — Download-all-as-zip on every entity's Documents card (fflate, foldered by type); `storage_usage_report()` + 🗄️ Reports card (by type/entity, 6-month intake, largest files).
- **SECTION H COMPLETE (101–112).** Suite: **952 pgTAP / 166 files**, all green from clean resets; everything prod-pushed and live-verified.
- **First live misfile audit (prod, NAS 3B):** 138 labeled docs re-read → 135 agree (97.8%), **3 real disagreements** banked for sentinel review: docs #122 + #176 (filed Rate Confirmation, read BOL) and #185 (filed POD, reads Rate Confirmation — POD coverage gates invoicing, so this one's worth the click).

### Section I (dispatch/ops) — day 2 evening
- **#114 ETA badges** — in-transit load rows carry ⏱ On track / Tight / HOS short / ETA-past-appt chips (the #52/53 feed, per-row; tooltip shows the estimate math and calls it an estimate).
- **#118 Load templates** — "⧉ Repeat lanes" chips on Dispatch: one click applies customer/lane/rate/stops; save-current-form-as-template with one input.
- **#119 Recurring scheduler** — pg_cron 06:10 daily `spawn_recurring_loads()`: due templates draft honest `pending` + awaiting-paperwork loads (notes-tagged "Auto-drafted…confirm with the broker", stops copied, load numbers real, cadence advances weekly/biweekly/monthly). Nothing rolls without a human.
- **Suite: 959 pgTAP / 167 files.** Prod pushed.

- **#125/#126 close-out** — the earlier `cancellation_analytics()` / `deadhead_patterns()` RPCs got their missing UI: 🚫 Cancellations card (per-customer cancel rate + "revenue walked", honestly labeled a ceiling since TONU isn't netted) and 🔄 Deadhead-patterns card (stranding states, worst repositioning pairs) on Reports. Devbox kit gained the `.env.local` regen step (same-commit rule).
- **#115/#116 assignment auto-suggest** — `suggest_assignment(lat,lon,when,lane)` ranks active drivers: free-first, then deadhead from ELD position (24h fresh) or last delivery (7d), lane history (365d), HOS hours; each row priced at GL all-in $/mi so a far-away driver is a **visible repositioning bill** (amber ≥$100), not a surprise. No-position drivers say "position unknown" — never a fake 0. Dispatch 🎯 Suggest-driver panel geocodes the pickup (cache-first) and one click fills driver+truck. Anon gate verified live (42501).
- **Suite: 967 pgTAP / 168 files** — all green from clean reset. Prod pushed, committed (`4ee6d61`, `1ab54c7`).

- **#117 stop reorder** — multi-stop loads reorder by drag handle (⠿, within pickup/delivery group) or ↑/↓ buttons (cab tablet), miles recalc on every reorder. Frontend-only; `faadcbc`.

- **#123 weather always-on** — the map's NWS severe-alert layer no longer waits for a toggle: alerts fetch unconditionally, trucks inside a warning are flagged in the subtitle/table at all times, and the polygon overlay auto-enables the moment a truck is actually in one (manual toggle still wins). `99fffd9`.

- **#124 PREP (radio transcript search)** — the shelf and the search, NOT the recorder: `radio_transcripts` (service_role-write-only — authenticated INSERT is refused by test, so nothing can fill it until the owner approves transcription), websearch FTS RPC with injection-safe `[[ ]]` snippet markers, office-only 🔎 card on the Radio page that states plainly "nothing is recorded or transcribed." **SECTION I COMPLETE (113–126).** Suite: **973 pgTAP / 169 files.** `c97ae86`.

### Section J (customer/revenue)
- **#132 rate-con turnaround** — `ratecon_turnaround_report()`: paper-first median/worst hours; extracted-at-booking, booked-before-paper (phone bookings) and no-paper-at-all buckets each reported separately — the negative-delta bucket is never dressed up as speed.
- **#135 lost-customer post-mortem** — `lost_customer_report()`: "lost" earned honestly (quiet > threshold AND 2× the customer's own booking cadence), ranked by trailing revenue; ⏱ + 🕳 Reports cards.
- **Own-goal caught & fixed:** the #125/#126 cards were defined but never mounted in Reports' render — now they are. (tsc can't catch an unused component; eyes did.)
- **Suite: 982 pgTAP / 170 files.** Prod pushed, anon 42501 verified, `e9564fe`.

- **#129 quote pricing feedback** — `quoted_rate`/`lost_reason` now captured on the quote queue (📨 card on Customers: record rate → Won/Lost-with-reason); `quote_pricing_report()` says the sentence win-rate never could: won vs lost premium **against our own booked lane average** (never claims market knowledge; unpriced quotes and never-run lanes reported separately, not hidden). 💬 Reports card. Suite: **989 pgTAP / 171 files**, anon 42501 verified, `1638c1e`.

- **#127/#133 customer share links + NPS-lite** — 🔗 Share-status on LoadDetail mints one idempotent, revocable, 90-day token per load; public `/share/<token>` page (load-share edge fn, drive-share bounded-capability pattern, IP rate-limited 30/min) shows status/route/appointments, coarse "near \<city\>" only while rolling, and a POD-on-file line; thumbs 👍/👎 + comment opens only after delivery, exactly once per link, banked in `load_feedback`. Live-verified: bogus token → 404, anon RPC → 42501. Suite: **997 pgTAP / 172 files.** `e306d01`.

- **#134/#137 customer one-pagers** — 📋 QBR card on CustomerDetail (this quarter vs last: loads, revenue, $/mi, cancels, real payment speed from invoice→paid, top lanes — ungeocoded lanes print as `?→?`, never invented) + 🕐 detention-policy card (their docks' GPS-measured dwell: avg/median, % past 2h free, detention hours and $ owed at $50/h, slowest facilities named; unmeasured stops counted). **Suite crosses 1,000: 1006 pgTAP / 173 files.** `3ad3c3c`.

- **#130/#136 onboarding + prospects** — ✅ onboarding checklist on CustomerDetail (7 items, each stating exactly what's missing — FMCSA item reads the weekly watcher's `customer_fmcsa_checks`, never re-fetches; card disappears at 7/7) and 🌱 prospect shelf on Customers (lead → contacted → quoting → `convert_prospect()` promotes to a real customer exactly once, name-matching instead of duplicating; unvetted leads say so). Suite: **1015 pgTAP / 174 files.** `1a1af8c`.

*(Run continues; closeout will finalize the count.)*

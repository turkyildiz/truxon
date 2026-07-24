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

- **#128 quote-response drafts (propose-only)** — 💡 Draft on the quote queue: `draft_quote_response()` prices from our own lane book (90-day book preferred, year fallback), folds in the won-quote premium when it's sane (±20%), rounds to $25, and writes the reply email; one click copies it and prefills the rate field. Unknown lanes return `no_history` and no number. **Nothing sends — the human quotes.** Suite: **1021 pgTAP / 175 files.** `4fafc72`.

- **#138 close-out — SECTION J COMPLETE (127–138).** Round-2 mining already runs (docs, 2h owner-approved mail miner, QBO, vision-on-click), so #138's real gap was the residue: `customer_enrichment_gaps()` counts remaining blanks per field and names the **dead ends** — customers with blanks and NO minable source left (no docs on them or their loads, no observed mail, no QBO link) — "those need a phone call, not more AI." 🧩 card on Customers with the call list. Suite: **1027 pgTAP / 176 files.** `d7db3f8`.

### Section L (web UX)
- **#153 omnibox documents** — global search now finds paperwork: filename/doc-type match, newest first, label names the owning load, and clicking lands on the owning entity's page (drivers/trucks were already searchable — the gap was docs). Deep content search stays on /docsearch. Suite: **1032 pgTAP / 177 files.** `a15694e`.

- **#160 who-changed-what** — field edits now leave a real trail: one compact diff line per human update (`rate: 1100.00 → 1200.00; miles: 300 → 350`) across loads/customers/drivers/trucks/trailers/maintenance, rendered in the activity feed every entity page already has. Robots (QBO mirror, geocoder — no session) stay silent by design so the human trail isn't buried; supersedes the names-only loads trigger from 07-16. Suite: **1037 pgTAP / 178 files.** `09858e5`.

- **#159/#155 list-level actions** — Loads rows now advance status one step inline (same guarded RPC as the detail page — a driverless load still refuses to go `assigned`; errors show under the row) and swap drivers from the list while pending/assigned. Invoices receivables gained checkboxes + a bulk bar: batch mark-sent for drafts, batch PDF download. Batch *email* deliberately omitted — recipients are chosen per send, no blind mass mail. QBO-synced rows excluded. Frontend-only (DB untouched, suite stands at 1037). `c40d74a`.

- **#156/#157 saved views + column chooser** — Loads (the big table) pilots both: "+ Save view" names the current filter set for one-click re-apply (chips with × delete), ⚙ Columns hides/shows the six non-essential columns; both persist per browser. Load#/Status/actions never hideable. Frontend-only; suite stands 1037. `185731c`.

- **#161/#162 undo toast + empty-state coaching** — UndoToast wired only where a TRUE inverse exists (load cancel ↔ uncancel, template delete ↔ restore — no fake undo on hard deletes); every ResourcePage empty list now coaches the next action (drop a rate con, forward a WO mail, add the unit), and Loads separates "filters match nothing" (one-click clear) from "no loads at all" (points at Dispatch). Frontend-only; suite stands 1037. `a6c5646`.

- **#165 real-user perf telemetry** — `web_vitals` table (RLS: users insert only their own rows, admin-only read) fed by a best-effort beacon (`perf.ts`: TTFB/FCP/LCP from the Performance API + session length, flushed on page-hide, no IP/UA stored); `web_perf_report()` gives p50/p95 per metric, avg session length, slowest pages by LCP p75; ⚡ admin-only Reports card; 90-day purge cron. Answers "is it fast for the person actually using it" with field numbers, not lab numbers. Suite: **1043 pgTAP / 179 files.** `b1c50da`.

- **#163/#166 chart consistency + a11y round 2 — SECTION L COMPLETE (153–166).** New `components/charts.tsx` is the one dataviz system (semantic `CHART` palette + `ChartGrid`/`ChartXAxis`/`ChartYAxis`/`ChartTooltip`/`LegendChip`); Dashboard + Invoices' 8 charts moved onto it, which **fixed a live dark-mode bug** — every grid was hardcoded `stroke=#e2e8f0` and stayed light-grey on dark backgrounds; now rides `var(--line)`, and tooltips are surface-themed instead of the unreadable white default. Accessibility: Modal → `aria-labelledby` the visible heading; sortable headers get `aria-label` with sort direction and `aria-hidden` decorative arrows; icon-only buttons across SentinelFeed/Drive/StopsEditor/Loads get accessible names (⚙ Columns also `aria-expanded`). Frontend-only, prod build clean; suite stands 1043. `5c82075`.

### Section M (reports/exec)
- **#170/#171 banker + tax-season export packages** — `banker_package()` bundles the P&L mirror, balance ratios, AR march, and the active fleet list (VIN/plate/purchase) into one lender worksheet (admin-only); `tax_season_package(year)` bundles IFTA fuel-by-state per calendar quarter + the 2290 power-unit list + depreciation for the accountant (admin/accountant). Both **only re-use audited primitives** — no new numbers — and each names its own gaps (not audited statements; IFTA = fuel purchased, not taxable miles; 2290 taxable weight untracked). 📦 Reports card downloads JSON. Suite: **1052 pgTAP / 180 files**, anon 42501 verified. `9347170`.

- **#169 insurance-renewal data room** — `insurance_data_room()` assembles carrier identity, FMCSA safety profile, trailing-12-month loss/exposure summary, driver roster (age, years experience, credential-currency flag from CDL/med-card dates), and the power-unit + trailer schedule into one underwriting export (admin/accountant). Audited primitives only; names its gaps (MVR detail, CDL class/endorsements, agreed stated values not tracked — `stated_value` = purchase price where recorded). 🛡️ button on the 📦 Reports card. One fixture catch: `loads.customer_id` is NOT NULL. Suite: **1059 pgTAP / 181 files**, anon 42501 verified. `e71ffbc`.

- **#174/#175 custom report builder + scheduling** — `saved_reports` (RLS owner/admin) is a named pick-list of metric keys drawn **only from the nightly `metric_snapshots` trend store**, so the builder can never invent a number. `report_metric_catalog()` offers pickable metrics with freshest values; `render_saved_report()` adds the prior-week value for a WoW delta. A weekly schedule + recipients get emailed Monday 07:00 by the cron-gated `report-send` edge function (reuses `sendMailAsTrux`; best-effort per report, only successful sends stamp `last_sent_at`); `due_scheduled_reports()`/`mark_report_sent()` are service-role-only. 🧱 Report-builder card on Reports. Test catches: pgTAP `is()` type-matching (numeric literals), service-role tested via `jwt.claims role`, and the trend store already holds 114 metrics so the catalog assertion checks containment not count. Suite: **1068 pgTAP / 182 files**, anon 42501 + edge 403-without-cron-key verified. `dfdb451`.

- **#168/#176 — SECTION M COMPLETE (167–176 targeted set done).** #168 board-pack refresh: the printable bank pack now carries an **Operations & safety** strip (weekly loads/on-time/detention/open-alerts, a single DOT-readiness % rolled from the CDL/medcard/DQF/inspection/ELD lines, CDL & med-card currency, 365-day safety events) and a **Pricing-discipline** card (won/lost quote premiums vs our own lane book + loss reasons) — the board sees ops+safety+pricing beside finance, all from existing audited data. #176 Forest daily-brief tune-up: `sentinel_open_summary`'s `top` list reorders for **diversity** — every critical always shows, warn/info capped at 2 per category and round-robined across categories, so a noisy category (six ops warnings) can no longer bury a lone fuel-theft flag; snooze still honored. Test catch: `trux_insights.category` is CHECK-constrained to money/cash/ops/compliance/maintenance/data. Suite: **1073 pgTAP / 183 files**, anon 42501 verified. `3b86ccd`.

### Section A leftovers (Lynx AI — infra-gated blocks)
- **#3/#4 extraction A/B harness + winner routing** — built the prod-verifiable half: `extraction_ab_scores` ledger (per-engine lynx-7b/nas-3b/cloud field-accuracy-vs-ground-truth + latency + cost — the accuracy layer the existing `llm_extractions` ledger lacked); `extraction_engine_ranking()` composite (accuracy − 1pt/sec − 1pt/10c) marking the winner per doc type; `apply_extraction_routing()` promotes each measured winner into `extraction_routing` **without clobbering human pins**; `best_extraction_engine(doc_type)` resolver ships a safe `nas-3b` default (the measured house finding) so routing works before any A/B pass lands. **Remaining/owner-side:** running the actual 50-verified-doc A/B on the boxes to populate the ledger. Suite: **1081 pgTAP / 184 files**, anon 42501 verified. `0c015ea`.
  - *Note:* Section A blocks #5/#6/#8 (reranker, embedding reindex, model bake-off) need Lynx GPU + NAS workers running live — not autonomously verifiable, deferred to owner box-side runs; #11 vision-drain needs a NAS vision worker that doesn't exist in-repo yet.

### Section D (ELD analytics v2)
- **#47/#48/#59 route deviation + GPS-confirmed POD chase** — `route_deviation_report()` sums the GPS breadcrumb path (great-circle hops) as *driven* miles against *booked* miles, flags loads materially over, and prices the out-of-route gap at GL all-in $/mi (loads without breadcrumb coverage are excluded, never counted as zero-deviation — the honest gap). `gps_confirmed_missing_pod()` (#59) surfaces delivered loads whose truck GPS sat within 0.75 mi of the consignee around the appointment but have **no POD filed** — the delivery physically happened, so it's the highest-confidence signature to chase. 🛰️ + 📍 Reports cards. Suite: **1088 pgTAP / 185 files**, anon 42501 verified. `6455a66`.

### Section E (Northstar)
- **#68/#69 churn early-warning + lane rate trend** — `customer_churn_watch()` catches the step *before* the gone-silent churn sentinel fires: customers **still booking** but whose recent volume (loads-per-30d, recent-60 vs prior-120 window) dropped materially vs their own baseline, so you can call while they're still talking. Distinct from #135 (already-lost) and the sentinel (gone quiet). `lane_rate_trend()` compares recent-90d $/mi vs the prior 9-month book per lane, splitting **falling** (lost pricing power or a softening market) from **rising**. 📉 + 📊 Reports cards. Suite: **1095 pgTAP / 186 files**, anon 42501 verified. `37372c0`.

- **#71/#74 driver fatigue flags + add-a-truck breakeven** — `driver_fatigue_watch()` finds long *ongoing* consecutive-work-day streaks via a gaps-and-islands pass over each load's pickup..delivery day-span (an honest days-on proxy — per-driver daily HOS isn't banked; only currently-running streaks are flagged). `truck_breakeven_analysis()` answers the 13th-truck question from real economics: the loaded miles/week a new truck must turn to cover its own weekly fixed cost at the fleet's contribution margin (avg $/mi − variable), set beside what the average truck actually runs, with a plain-English clear/tight/risky verdict. 😴 + 🚚 Reports cards. Suite: **1101 pgTAP / 187 files**, anon 42501 verified. `5645c6f`.

- **#65/#73 forecast MAPE + retire-a-truck what-if — SECTION E TARGETS DONE.** `forecast_snapshots` banks each week's revenue prediction (Monday cron `capture_revenue_forecast`); `forecast_mape_report()` grades matured weeks against realized revenue (MAPE + mean bias, positive = forecasting high) — empty until snapshots mature, which is honest: it fills as the weeks turn. `truck_retirement_scenario()` mirrors #74: it redistributes a unit's 12-week freight across the survivors against a ~2500 loaded-mi/wk practical ceiling, reports the fixed cost saved and the revenue at risk if the fleet can't absorb it, with a plain verdict. 🎯 + 🅿️ Reports cards (retirement is a truck picker). Suite: **1108 pgTAP / 188 files**, anon 42501 verified. `b8ec5bc`.

### Section G (playbook flips)
- **Six playbook metrics flipped needs_data → live**, each because a function this run built now computes it: **#68** Forecast Accuracy (revenue) MAPE → `forecast_mape_report()` [#65]; **#297** Deadhead per Dispatch (best terminal) → `deadhead_patterns()` [#126]; **#400** Customer Churn Rate (revenue) → `lost_customer_report()` [#135]; **#399** Customer Churn Rate (accounts) → `segment_economics` customer_churn_pct; **#453** Bid Win Rate + **#476** Quote-to-Award → `sales_pipeline()` win_rate_pct (the #129 quote-pricing capture sharpens the priced side). Single-terminal best/worst variants collapse to the fleet value (accepted pattern — one region). **Playbook now ~199 live.** Suite: **1112 pgTAP / 189 files.** `d02edd9`.
  - *Noted (owner-side):* 66 pre-existing live metrics carry an empty `source` string — a data-quality gap present before this run, not introduced by these flips; worth a backfill pass but out of scope here.

- **Playbook source backfill (the 66 gap, resolved honestly)** — 47 of the 66 sourceless-live metrics now name their computing function: `company_scorecard()` for the operational/financial/maintenance omnibus (OR, rev/mile, cost/mile, contribution margin, DSO, bad debt, invoice cycle, empty %, loaded ratio, miles/loads per tractor, length of haul, trailer ratio, equipment age, driver/vehicle OOS, new-logo %) and `safety_summary()` for accidents-per-million. The remaining **19 are deliberately left blank** — customer concentration, injury-per-million, HOS-per-million, payroll uptime: no single function clearly computes them, and a guessed source is worse than an honest empty one. No statuses flipped. Sourceless-live: **66 → 19.** Suite: **1116 pgTAP / 190 files.** `39cc67f`.

### Section F (Sentinels v3)
- **#77/#78 billing-hygiene sentinels** — two ways money gets stuck *after* the work is done, spliced into `sentinel_scan` (new lineage head `20260724000012`). **#77 invoice_unsent**: a draft invoice sitting >48h that never went out the door (detail quantifies the unbilled dollars). **#78 pod_not_invoiced**: a delivered/completed load with its POD on file but no invoice after 72h — we have the proof, we just haven't billed. Both cash-category warns; both auto-resolve the moment the invoice is sent / the load is invoiced. Suite: **1121 pgTAP / 191 files**, anon 42501 verified. `7b878fe`. Two harness lessons: `sentinel_scan` internally calls the admin-gated `weekly_report` (service_role alone is refused inside), and `loads.invoice_id` is trigger-managed so the #78 auto-resolve test bills through `create_invoice()`.

*(Run continues; closeout will finalize the count.)*

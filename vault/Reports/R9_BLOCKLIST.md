---
title: R9 block list (1–200)
tags: [r9, plan]
---

> **Recovered 2026-07-23** from the old box's session transcript after the machine
> swap (the list had never been written to the repo — now it is). Cross-reference
> [[ACCOUNTABILITY_R9_2026-07-23]] for what's shipped. Remaining at recovery time:
> A 3–6/8–9/11 · D 47–48/59 · E 64–74 · G ~7 flips · H 102–106/108–109/111–112 ·
> I 114–119/123–126 · J 127–130/132–138 · L 153/155–157/159–163/165–166 ·
> M 168–171/174–176 · N 177–186 + O 187–194 (protected test window Jul 28–30) ·
> P 195–199 + #200 closeout Jul 31.

Here's **R9: the next 200** — all runnable without you. Sectioned so you can redirect me anytime; honest flags where data or time gates a block.

## A. Lynx AI upgrades (1–12)
1. Pin the 7B model warm (kill cold-start latency for Forest heavy calls)
2. Vision tiling — 200+ DPI rate-con scans in halves, merged (sharper small print)
3. Extraction A/B harness: Lynx-7B vs NAS-3B vs cloud on 50 human-verified docs, scored
4. Route each doc type to the measured winner
5. Doc-search reranker (7B scores top-20 candidates)
6. Embedding upgrade eval (nomic → bge-m3) + GPU reindex if it wins
7. LLM observability: per-call latency/accuracy/cost ledger + weekly rollup
8. Gemma2-9B/Llama-3.1-8B bake-off vs qwen for extraction
9. Prompt-cache tuning for repeat doc types
10. Lynx health dashboard card in /security (VRAM, temp, queue depth)
11. Nightly vision backlog drain job (idle-hours batch)
12. Auto-fallback drill: kill Ollama, verify NAS/cloud failover fires cleanly

## B. DOT / compliance build-out (13–28) — *closes the audit-pack gaps*
13. Medical-card fields on drivers (number, expiry) + form section
14. Medical-card expiry sentinel (60/30/7-day warnings)
15. CDL expiry sentinel (same ladder)
16. **CDL backfill from license docs on file via Lynx vision** (6 missing numbers)
17. Medical-card backfill from Medical Card docs the same way
18. Annual-inspection record type in maintenance + due-by-anniversary tracking
19. Annual-inspection sentinel (truck overdue = OOS risk)
20. MVR review log (date reviewed, reviewer, result) + annual reminder
21. Drug/alcohol program tracker (enrollment, random-pool, test log — records only)
22. Driver Qualification File completeness page (one screen: what's missing per driver)
23. DQF completeness % on the scorecard + playbook flip
24. Plate-expiry sentinel (field exists, no watcher)
25. DVIR adoption nudge — Forest radio reminder when a driver starts without one
26. DVIR compliance % per driver on scorecards
27. dot_audit_pack → Forest catalog + Reports page card
28. Clearinghouse query log stub (records; the actual query is yours)

## C. Accounting v2 (29–44)
29. QBO fee write-off **proposals** (propose-only cards; you approve each)
30. Denim statement vs captured-fees reconciliation report
31. Fee-sliver aging sentinel (slivers >90d = books getting crusty)
32. Factoring cost dashboard: effective rate %, fees by month, vs DSO gained
33. Invoice PDF statements per customer (monthly, printable)
34. Customer statement email drafts (propose-only)
35. Revenue-recognition check: delivery date vs invoice date drift report
36. Credit-memo tracking from QBO mirror
37. Payment-application audit (payments landing on wrong invoices)
38. Budget v2: seasonality-aware seeding (month-of-year factors)
39. Budget variance sentinel (line >20% over, 2 months running)
40. gl_cfo_snapshot: add equipment-gap-adjusted operating ratio
41. Break-even dashboard card showing basis + equipment gap explicitly
42. Per-truck P&L (revenue on its loads − its direct costs − its payment)
43. Truck ROI ranking (which unit earns its keep) once payments entered
44. Depreciation schedule builder from purchase_price/date (straight-line, books-independent)

## D. ELD analytics v2 (45–62)
45. Harsh-braking **proxy** from breadcrumb speed deltas (DriveHOS won't give events; derive Δmph/Δt)
46. Harsh-event driver scorecard integration + coaching list
47. Route-deviation detection (actual trail vs Valhalla planned route)
48. Out-of-route miles % per load + cost attribution
49. Fuel-stop analysis: where drivers actually fuel vs cheapest on-route
50. Idle heat-map (where the fleet idles — customer docks vs truck stops)
51. Dock-time league table by facility (worst detention offenders with evidence)
52. ETA prediction per active load (position + HOS + historical pace)
53. Late-risk alerts to dispatch (ETA > appointment while still fixable)
54. Weekend/after-hours utilization report
55. Truck-day utilization: revenue days vs idle days per unit
56. Speeding trend per driver (weekly delta, not just totals)
57. eld_daily_miles gap-filler job (retro-fetch missed days nightly)
58. Unit 05/08 dark-ELD escalation ladder (repeat critical + daily brief line)
59. GPS-confirmed delivery: breadcrumbs at consignee → auto-suggest POD request
60. Live map: breadcrumb tail per truck (last 4h)
61. Stop-level dwell percentiles (P50/P90) per facility for rate negotiations
62. IFTA quarterly close package (Q3 prep, printable)

## E. Northstar (63–74)
63. Breakdown-ML readiness report (weekly: rows banked, features coverage, ETA to trainable)
64. Feature bank v2: add fault-proxy features (MPG drift, idle spikes)
65. Forecast MAPE tracking (forecasts old enough to score now)
66. Revenue forecast v2: lane-seasonality adjusted
67. Cash forecast v2: factoring advance timing modeled (Denim pays ~2 days)
68. Customer churn early-warning (booking cadence drop-off)
69. Rate-trend detector per lane (are your rates drifting from your history)
70. Load-acceptance advisor v2: margin + HOS + repositioning value in one score
71. Driver fatigue-pattern flags (long-day streaks from HOS)
72. Insurance-renewal prep pack (loss runs, safety trends, exposure)
73. What-if: truck 13 retirement scenario (its loads redistributed)
74. Growth model: 13th truck breakeven analysis from real economics

## F. Sentinels v3 (75–88)
75. Fee-sliver write-off reminder (monthly digest to you)
76. Detention detected at pickup but not billed (currently delivery-biased)
77. Invoice created but never sent >48h
78. POD on file but load not invoiced >72h
79. Driver pay vs load pay mismatch check
80. Fuel card used on day driver wasn't dispatched
81. Toll on a route with no matching load
82. Same-day duplicate load entry guard
83. Customer booked past exposure limit (pre-book, not just post)
84. QBO sync drift (mirror vs books row counts diverge)
85. Storage-bucket growth anomaly (runaway uploads)
86. Sentinel findings weekly digest — grouped, deduped, one email
87. Sentinel snooze/ack from the daily brief
88. Finding-quality review: auto-resolve stale findings older than 30d unseen

## G. Playbook march (89–100)
89–100. Twelve more flips from the computable frontier: accessorial mix %, invoice accuracy rate (credit-memo basis), settlement dispute rate (payroll data present?), working-capital ratio trend, fuel-surcharge capture (needs rate-con line items — Lynx extraction), revenue per dispatcher, claims frequency, maintenance planned-vs-reactive trend, driver referral rate, tenure distribution, cost per dispatch, break-even loads/week. Each: honest source or explicit needs_data close.

## H. Docs / RAG (101–112)
101. Classification sweep: every unlabeled doc typed by NAS-3B
102. Auto-filing v2: misfiled doc detector (claims to be POD, looks like rate con)
103. OCR quality score per doc + re-scan queue for garbage scans
104. Rate-con line-item extraction (fuel surcharge, accessorials as fields)
105. Rate-con ↔ load reconciliation (extracted rate vs booked rate mismatches)
106. BOL ↔ POD pairing check per load
107. Doc search: filters (type, date, customer) in UI
108. Doc search: "more like this" via embeddings
109. Team Drive re-index freshness job + staleness sentinel
110. Document retention report (what's on file per entity, gaps)
111. Drive: bulk download as zip per load/customer
112. Drive: storage usage dashboard

## I. Dispatch / ops (113–126)
113. Dispatch board: HOS-remaining column live (eld_fleet_live wire-in)
114. Dispatch board: ETA + late-risk badges
115. Load builder: auto-suggest driver+truck by hours/position/history
116. Repositioning cost shown when assigning far-away driver
117. Multi-stop load UX polish (stop reorder drag)
118. Load templates for repeat lanes
119. Recurring-load scheduler
120. Load clone action
121. Check-call log per load (timestamped notes timeline)
122. Dispatch shift-handoff summary (what's rolling, what's hot)
123. Weather overlay on dispatch map (NWS alerts already flow)
124. Radio: transcript search prep (schema + UI; transcription itself gated on your OK)
125. Load cancellation analytics (who cancels, cost of cancels)
126. Deadhead optimizer report: worst repositioning patterns

## J. Customer / revenue (127–138)
127. Customer portal read-only share links (tokened load status page)
128. Auto quote-response drafts from lane history (propose-only)
129. Quote win/loss analytics + pricing feedback loop
130. Customer onboarding checklist (credit, FMCSA vet, packet)
131. Broker packet generator (W9, insurance cert, authority — one PDF)
132. Rate-confirmation turnaround time metric (received → booked)
133. Customer NPS-lite (post-delivery thumbs up/down via portal link)
134. Top-customer QBR one-pager generator
135. Lost-customer post-mortem report (revenue that stopped)
136. Prospect tracker (FMCSA-vetted leads list)
137. Detention-policy one-pager per customer (from their actual dwell data)
138. Customer contact enrichment round 2 (docs + email mining)

## K. Mobile v15 (139–152)
139. Offline voice v2: more intents (fuel receipt note, breakdown report)
140. Offline voice: Spanish STT/TTS models (es driver support)
141. Breakdown report flow (photo + location + voice note → maintenance + dispatch alert)
142. Fuel receipt capture → fuel_transactions pending match
143. Driver settlement statement view (their pay per load, weekly)
144. Load history for driver (their completed loads, miles, pay)
145. In-app document wallet (their CDL/med-card photos, expiry reminders)
146. Push notification preferences screen
147. Companion app dark-mode audit
148. Tablet kiosk mode for shop (DVIR + maintenance station)
149. App diagnostics screen (GPS health, sync queue, version)
150. Photo compression tuning (POD upload size/quality)
151. Batch OTA: staged rollout support (one truck first, then fleet)
152. v15 release with everything above

## L. Web UX (153–166)
153. Global search: include documents + drivers + trucks
154. Keyboard shortcuts (g+l loads, g+i invoices, / search)
155. Bulk invoice actions (send batch, mark batch)
156. Saved filters per page
157. Column chooser + persistence on big tables
158. CSV export on every table
159. Inline edit on load list (status, driver swap)
160. Activity feed per entity (who changed what, from audit log)
161. Undo toast for destructive actions
162. Empty-state coaching (new-user guidance per page)
163. Chart consistency pass (one dataviz system everywhere)
164. Print stylesheets (invoices, reports)
165. Session-length/perf telemetry (real-user timing)
166. Accessibility pass round 2 (focus traps, screen-reader labels)

## M. Reports / exec (167–176)
167. Monthly owner package: one PDF (P&L, AR, ops, safety, playbook movers)
168. Quarterly board pack refresh with new metrics
169. Insurance-renewal data room export
170. Banker package (financials + ratios + fleet list)
171. Tax-season package for accountant (IFTA, 2290 data, depreciation inputs)
172. Weekly flash v2: add pricing-discipline + DOT-readiness lines
173. Anomaly digest: "what changed this week" auto-narrative
174. Custom report builder lite (pick metrics, save, schedule)
175. Report scheduling (email Monday 7am set)
176. Forest daily brief tune-up (dedupe, priority ordering)

## N. Testing (177–186)
177. E2E: full load lifecycle (create→dispatch→deliver→invoice→pay)
178. E2E: factoring lifecycle with fee sliver
179. Frontend component tests (top 10 money-path components)
180. Mobile integration tests (offline queue drain)
181. Edge-fn tests: qbo-sync mapper, eld-sync mapper
182. Chaos drill: kill each cron for a day, verify watchdog catches all
183. Load test: 10× data volume on heavy RPCs
184. Restore drill from INDIANCREEK copy (prove offsite actually restores)
185. pgTAP coverage report (which functions lack tests)
186. CI time budget (parallelize if suite >5 min)

## O. Perf / infra (187–194)
187. Materialized views for the 5 heaviest dashboard RPCs + refresh cron
188. Frontend bundle audit round 2 (leaflet/chart splitting)
189. Read-model caching for scorecard (5-min TTL)
190. NAS container image updates (monthly discipline)
191. INDIANCREEK capacity plan (that 99%-full volume)
192. Tailscale ACL review (least-privilege between nodes)
193. Postgres vacuum/bloat review on hot tables
194. Log retention policy (edge fn logs, diag tables)

## P. Security / DR (195–200)
195. Quarterly security re-audit (gate classes, RLS, secrets age)
196. Dependency update sweep (npm/flutter/deno) + regression
197. Secret-rotation drill (CRON_SECRET rotate end-to-end)
198. Honeypot/honeytoken hit review + tuning
199. OTA manifest signing (close the last residual from the security posture)
200. R9 closeout: full regression, prod sweep, accountability report, memory

**Gated (not in the 200):** radio transcription (records people — your explicit OK), QBO write-off *execution* (proposals only), truck payment values (your numbers), OTA publish clicks, INDIANCREEK prune.

Starting at Block 1 (warm model on Lynx) and running down, same discipline as R8 — suite green before every push, findings surfaced as I go.

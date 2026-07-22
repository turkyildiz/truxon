---
name: wo-email-intake
description: "Email → work-order intake: forward a shop sheet to trux@ and Trux drafts a maintenance record for review"
metadata:
  node_type: memory
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

Shop maintenance work orders can be captured by email. **Usage:** forward the shop's sheet (PDF or a clear photo) to trux@truxon.com with the subject starting with **WO** (or "work order" / "repair order" / "shop invoice"). Trux extracts unit #, service type, description, cost, odometer, date, shop, invoice # and creates a DRAFT `maintenance_records` row (`source='email'`, `needs_review=true`, `status='scheduled'`), pushes the admins, and replies. The owner reviews it in Maintenance → Repair Log ("Awaiting Review") and taps Confirm (flips to `completed`). Drafts don't count in CPM/P&L until confirmed. Same extraction also available in-app via the "📄 Add from sheet" button (extract-pdf `mode=work_order`).

**Trust model (decided with owner 2026-07-19):** *forward-in* — the trusted sender is the staff member who forwards, so it reuses the existing staff-only email door ([[project-truxon]] trux-inbox), no external-sender allowlist. Autonomy = *draft + notify* (not auto-final, not propose-only). Security shape: inbound email can reach exactly ONE bounded write, `create_work_order_draft(jsonb)` — never the general agent — so nothing in a sheet can trigger any other action; attachments are data, not instructions.

Built this session (local, **unpushed**): migration `20260719340001_work_order_intake.sql` (source/needs_review cols + bounded RPC), `_shared/extract_llm.ts` (shared LLM extractor + workOrderPrompt), extract-pdf work_order mode, trux-inbox WO branch + owner push, Maintenance.tsx review UI, test `15_work_order_intake_test.sql`. Needs `LLM_API_KEY` set for extraction (already used by extract-pdf). Known gap: scanned PDFs with no text layer aren't rasterized server-side — text PDFs and photos work; the reply tells the sender to send a photo otherwise. Part of the [[project-truxon]] maintenance module.

**EXTENDED 2026-07-20 — "Forest files your documents":** the email door (now forest@truxon.com) also auto-files ANY emailed document, not just work orders. `_shared/doc_filing.ts`: classifyDocument (text-PDF→text, image→vision, SCANNED PDF→unpdf renderPageAsImage→vision) + matchEntity (truck/trailer by unit#, driver/customer by name, load by number) + fileDocument (upload to 'documents' bucket + documents row). trux-inbox filing branch runs for emails with attachments that aren't work orders / action requests: auto-file + notify owner + reply what it filed / what needs a unit#. Gated by the SAME sender check (active admin/dispatcher/accountant profile email, SPF/DKIM/DMARC anti-spoof). VERIFIED live: scanned truck-16 registration → filed under truck unit 16 documents. trux-inbox `mode:'status'` = debug read of recent log + equipment docs. Commit aa6fa73.

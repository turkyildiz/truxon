# Truxon TMS — User Guide

Everything a dispatcher, driver, accountant, or maintenance user needs to run
Truxon day to day. For account setup, backups, and integrations see the
[Admin Guide](ADMIN_GUIDE.md); for architecture see [TECHNICAL.md](TECHNICAL.md).

- **App:** https://truxon.com
- **Sign in:** the blue **Log In** button, top-right of the marketing site.
- **Support:** your company admin creates accounts and resets access.

---

## 1. Signing in & your account

1. Go to https://truxon.com and click **Log In / Sign Up**.
2. Enter the email and password your admin gave you.
3. You land on the page your role starts on (dispatchers/office → Dashboard,
   drivers → their welcome page).

**Change your password:** click the **🔑** button in the top-right header,
enter a new password twice, Save. You stay logged in.

**What you can see** depends on your role (admin, dispatcher, accountant,
maintenance, driver). If a menu item isn't listed for you, your role doesn't
have access — ask an admin if you need it.

---

## 2. The Dashboard

The office home screen. At a glance:

- **This week's** revenue, miles, loads, and average rate per mile (Mon–Sun).
- **Trucks available** and **active drivers** right now.
- **Revenue-by-day** bar chart and a **load-status** pie chart.
- **⚠️ Licenses expiring within 30 days** — driver names + dates, so nothing
  lapses.
- **Active loads** — everything assigned or in transit; click any row to open
  it.

Numbers refresh automatically every minute.

---

## 3. Customers

The **Customers** page lists **every** customer (active and inactive, shown
by a status badge) with a search box (matches company or contact name).

**Add a customer two ways:**

- **Quick Add from paperwork** — drag a rate confirmation or broker setup
  packet onto the drop zone at the top. Truxon reads the company name,
  contact, phone/email, remit-to billing address, terms, and MC# and opens
  the New Customer form pre-filled. Review and Save.
- **Manual** — click **+ Add**, fill the form.

Each customer holds: company name, primary + secondary contacts, phone, fax,
toll-free, email, payment terms, billing address, active flag, and notes.

**Documents & notes:** click **Docs** on any customer row to attach files
(contracts, rate agreements, insurance) and leave timestamped notes.

---

## 4. Drivers, Trucks, Trailers

Each has its own list with search, **+ Add**, and per-row **Docs** for files
and notes.

- **Drivers:** name, phone, email, address, license number + expiration, DOB,
  hire date, **pay per mile**, **Empty Miles Paid** checkbox (+ empty-mile
  rate when ticked), status, and notes (medical/drug-test dates). Expiring
  licenses surface on the Dashboard.
- **Trucks / Trailers:** unit number, make/model/year, VIN, **plate number +
  expiry**, monthly cost, in/out-of-service dates, status
  (available/in use/maintenance/retired), notes.

Attach registrations, insurance, and inspection docs via **Docs**.

---

## 5. Maintenance

Log a repair with **+ Log Repair**: equipment (truck or trailer), date
completed, cost, shop/technician, and a description of the work. Attach the
receipt or invoice via **Docs**.

---

## 6. Dispatch — creating a load

The **Dispatch** page is where loads are born. Two paths:

### AI-assisted (drop a PDF)

1. Drag a **rate confirmation / load tender PDF** onto the drop zone (or
   **Choose PDF**). Scanned PDFs work too — Truxon reads the images.
2. Truxon fills in: customer, broker load/PRO number, equipment type, rate,
   special terms, and **every stop** (pickup and delivery — including
   multi-stop loads) with addresses, appointment times, and PU/delivery
   numbers.
3. **Mileage calculates automatically** across all stops once addresses are
   in.
4. If the broker on the PDF **isn't in your customer list**, a banner offers
   **"add & select"** (creates the customer with just the name — fill billing
   details later) or pick an existing one.

### Manual

Fill the same form by hand. Key fields:

- **Customer** (required), **Broker Load / PRO #**, **Equipment Type**.
- **Rate**, **Miles**, **Empty Miles** (rate-per-mile shows live).
- **Pickup / Delivery stops** — see below.
- **Driver, Truck, Trailer** (assign now or later).
- Special terms, notes.

### Multi-stop loads

Under the route section you'll see **Pickup** and **Delivery** groups. Use
**+ Add pickup location** / **+ Add delivery location** to add as many stops
as the load needs. Each stop has its own facility name, address, appointment
time, and PU#/delivery#/PO. **📍 Recalculate miles (all stops)** routes
through every stop in order.

Click **Create Load** — you're taken to the new load's page. Truck/trailer
are marked in use; a load with a driver + truck starts as **Assigned**.

---

## 7. Loads — the workflow

The **Loads** page lists loads with filters (search by load # / broker # /
address, status, customer, driver, pickup date range).

Open a load to see its full detail and move it through the 6-step workflow:

**Pending → Assigned → In Transit → Delivered → Completed → Billed**

- Use the **→** button to advance one step, **← back** to correct a mistake.
- You can't mark **Assigned** without a driver and truck.
- You can't mark **Billed** without an invoice (that happens automatically
  when you invoice it).
- **Billed loads are locked.** To change one, void its invoice first.

On the load page you can also:

- **Edit** everything (customer, broker #, all stops, equipment, rate, miles,
  empty miles, driver/truck/trailer, terms, notes).
- See the **full route** — every stop with times and reference numbers.
- **Documents** — attach BOLs, PODs, rate cons, photos.
- **Notes & Activity** — leave notes; every status change is logged
  automatically with who and when.

---

## 8. Accounting (Weekly Report)

The **Accounting** page shows a **Monday–Sunday** settlement for any week
(use ← Prev / Next → / This Week).

- Totals: loads, miles, revenue, average rate per mile.
- **By Truck** and **By Driver** breakdowns.
- **Driver Pay** = loaded miles × pay-per-mile, **plus** empty miles ×
  empty-mile rate for drivers who have that turned on. An **Empty Mi.** column
  shows what's being paid for.

Invoicing/accounting of record is handled in **QuickBooks** (see Admin Guide).

---

## 9. Invoices

Generate a Truxon invoice from completed loads:

1. **+ Generate Invoice**, pick a customer, check the completed un-billed
   loads to include, **Generate**. Those loads become **Billed**.
2. Per invoice: **PDF** (download a branded invoice), **Mark Sent**,
   **Mark Paid**, and **Void** (reverts its loads to Completed so you can
   re-bill — the only way to unlock a billed load).

Invoice branding (company name, address, phone, MC#) comes from **Settings**.

---

## 10. Personal Drive & Team Drive

Two Dropbox-style file areas in the sidebar:

- **📁 Personal Drive** — your private files. **No one else can see them, not
  even an admin.** Good for your own paperwork, receipts, notes.
- **🗂️ Team Drive** — shared with everyone on the team. Anyone can upload and
  view; you can delete your own files (admins can delete any).

Both support optional **folders**, **search**, upload (up to 100 MB/file),
download, and delete. Everything is backed up nightly to the company NAS.

---

## 11. Global search

The search box in the header (office roles) finds loads (by load #, broker #,
or address), customers, drivers, and trucks as you type. Click a load result
to jump straight to it; other results take you to that list, filtered.

---

## 12. Trux — the Truxon assistant

The **🤖 Trux** button (bottom-right, every page) opens a chat with Truxon's
built-in agent. Trux answers with live data and only within *your* role's
permissions:

- **Owner / dispatcher:** "Give me a recap — how are we doing vs last week?",
  "Which trucks and drivers are free?", "Find loads for TQL", or ask it to
  create a load / assign a driver+truck / advance a status.
- **Accountant:** recaps and weekly reports (per-driver pay, per-truck revenue).
- **Driver:** "What are my loads?", load details, and marking in-transit /
  delivered.
- **Maintenance:** equipment status and recent maintenance records.

Anything that *changes* data is only ever **proposed** — Trux shows a card and
nothing happens until you press **Confirm**. Every executed action is logged
to an audit trail under your name.

---

## 13. Tips

- **Tablet-friendly:** the whole app works on a tablet; the sidebar collapses
  behind the ☰ menu in portrait.
- **Nothing saves on error:** if a save fails you'll see a red message and
  your typing is preserved — fix and retry.
- **Rate-con extraction is capped** at 30 PDFs per user per hour (raise on
  request) — a guard against runaway AI cost, not a normal limit you'll hit.

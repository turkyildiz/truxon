# Truxon TMS — Admin Guide

For the company **admin**. Covers accounts, roles, company settings, the
QuickBooks connection, backups, and day-to-day operational care. For end-user
features see the [User Guide](USER_GUIDE.md); for architecture see
[TECHNICAL.md](TECHNICAL.md).

---

## 1. Users & roles

**Create/manage users:** the **Users** page (admin only). New users are
created here — public sign-up is disabled by design. Deactivating a user bans
their auth account and revokes their sessions immediately.

### Roles and what each can do

| Role | Access |
|------|--------|
| **admin** | Everything, plus Users and Settings. |
| **dispatcher** | Loads, Dispatch, Customers, Drivers, Trucks, Trailers, Maintenance, Accounting, Invoices, Dashboard, both Drives. |
| **accountant** | Read operations + Accounting & Invoices (no create/dispatch of loads beyond edits), Dashboard, both Drives. |
| **maintenance** | Trucks, Trailers, Maintenance, both Drives. |
| **driver** | Their welcome page + both Drives. |

Access is enforced in the database (row-level security), not just the menu —
a role can't reach data it shouldn't even by typing a URL or hitting the API.

### First admin

Created once in the Supabase dashboard (Authentication → Add user, auto-
confirm), then in the SQL editor:
```sql
update public.profiles set role = 'admin' where username = '<their username>';
```
Everyone else is created from the app's Users page.

---

## 2. Company settings

**Settings** page (admin). Company name, address, phone, email, MC number —
these appear on the **invoice PDF header**. Save; invoices pick up the change
immediately.

---

## 3. Invoicing & QuickBooks

QuickBooks Online is the **accounting system of record** for Aida Logistics.

- Truxon generates a branded invoice **PDF** and tracks Sent/Paid/Void status
  for operational visibility.
- **Real receivables, aging, and books live in QuickBooks.**
- The QuickBooks company is **Aida Logistics LLC** and is reachable through
  the claude.ai QuickBooks connector (verified working).

**Planned in-app sync** (needs owner action): an Intuit developer app +
OAuth so Truxon can auto-create a QBO invoice when a load is marked Sent.
Until then, invoices are booked into QBO manually or via the connector.
See `docs/MIGRATION_PUNCHLIST.md` item 3.

---

## 4. Backups (3-2-1-1-0)

Data is protected on multiple layers:

- **Cloud** — Supabase keeps its own daily server-side backups.
- **On-prem** — a Docker container (`truxon-backup`) on the UGREEN NAS pulls
  every night at **02:00**: an encrypted `pg_dump` of the database **and** an
  encrypted tar of **all storage buckets** (documents, Personal Drive, Team
  Drive), 30-day retention, in `docker/truxon-backup/backups/`.
- **Immutable** — UGOS Snapshot on the `docker` shared folder (daily, 30-day
  retention): the copy ransomware can't alter.
- **Verified** — the restore-test script decrypts the newest dump into a
  throwaway Postgres and checks row counts (`deploy/backup/restore_test.sh`).

**The gpg passphrase is the one thing that can't be recovered — keep it in a
password manager.** Without it the backups can't be restored.

> **After adding the drives:** the live NAS backup container has its own
> embedded copy of `storage_backup.py`. Push the updated script (it now
> backs up all three buckets via the `BACKUP_BUCKETS` env, default
> `documents,personal,team`) to the container so Personal/Team Drive files
> are included. Until then only `documents` is backed up on-prem.

---

## 5. Security posture

- Public sign-up **off**; only admins create accounts.
- Every table has row-level security; the load workflow and invoicing rules
  run in SECURITY DEFINER database functions, not client code.
- Reporting functions (dashboard, global search, weekly report) and
  document/notes/drive access are **role-gated** — driver and maintenance
  logins never see company financials, the customer list, or others' files.
- **Personal Drive is owner-only** even from admins; **Team Drive** is
  all-staff read + own-file delete.
- The AI PDF function is auth/role-gated, size-capped (15 MB), and
  rate-limited (30/user/hour, override `EXTRACT_RATE_MAX`).
- **Rotate the admin password and revoke any API tokens shared in plain
  text.** Store secrets in a password manager.

---

## 6. Data migration from ITS Dispatch

The historical data from ITS Dispatch (customers, drivers, equipment, ~983
loads with their documents) was migrated on 2026-07-16. Tooling and the
outstanding decisions are in `deploy/migration-its/` and
`docs/MIGRATION_PUNCHLIST.md`. Keep ITS in read-only as an archive for a
while before cancelling.

---

## 7. Operational care

- **Watch expiring licenses** on the Dashboard.
- **Void, don't edit** billed loads.
- **Weekly settlement** pays empty miles only for drivers with the box
  checked — confirm those are set correctly before running payroll.
- New schema changes go in `supabase/migrations/`; never edit an applied one.

-- QBO→load billing reconcile: the fix for the "unbilled" list showing loads QBO
-- has already invoiced. acct_reconcile_qbo_billing() links a completed load to a
-- live QBO mirror invoice (matched by the LOAD <ref> = reference_number) and
-- marks it billed — the create_invoice() transition, sourced from QBO.
-- Proves: normalized matching (leading-zero refs), dry-run changes nothing, the
-- real run flips only true matches, void invoices are ignored, no-match loads
-- stay completed, it's idempotent, and non-admins are refused.
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

-- admin to run the module as
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000d01'::uuid, 'recon@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000d01';
-- a dispatcher (non-admin) for the authz check
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000d02'::uuid, 'disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000d02';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000d01"}', true);

insert into public.customers (company_name) values ('Recon Freight');

-- Live QBO mirror invoices (source='qbo'), each carrying its LOAD refs.
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, qbo_id, qbo_doc_number, qbo_load_refs)
  select 'QBO-5001', id, now() - interval '20 days', now() - interval '10 days', 1150, 'paid', 'qbo', 'q5001', '5001', array['2004797']
  from public.customers where company_name = 'Recon Freight';
-- leading-zero ref on the QBO side, bare ref on the load side → must still match
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, qbo_id, qbo_doc_number, qbo_load_refs)
  select 'QBO-5002', id, now() - interval '18 days', now() - interval '8 days', 1500, 'sent', 'qbo', 'q5002', '5002', array['0011178']
  from public.customers where company_name = 'Recon Freight';
-- a VOID invoice — its ref must NOT link its load
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, qbo_id, qbo_doc_number, qbo_load_refs)
  select 'QBO-5003', id, now() - interval '15 days', now() - interval '5 days', 0, 'void', 'qbo', 'q5003', '5003', array['5551234']
  from public.customers where company_name = 'Recon Freight';

-- Completed, un-invoiced loads (the "unbilled" list)
insert into public.loads (load_number, customer_id, status, reference_number, pickup_address, delivery_address, rate, delivery_time)
  select 'L-RECON-1', id, 'completed', '2004797', 'A', 'B', 1150, now() - interval '9 days' from public.customers where company_name = 'Recon Freight';
insert into public.loads (load_number, customer_id, status, reference_number, pickup_address, delivery_address, rate, delivery_time)
  select 'L-RECON-2', id, 'completed', '9999999', 'A', 'B', 500, now() - interval '7 days' from public.customers where company_name = 'Recon Freight';
insert into public.loads (load_number, customer_id, status, reference_number, pickup_address, delivery_address, rate, delivery_time)
  select 'L-RECON-3', id, 'completed', '5551234', 'A', 'B', 800, now() - interval '6 days' from public.customers where company_name = 'Recon Freight';
insert into public.loads (load_number, customer_id, status, reference_number, pickup_address, delivery_address, rate, delivery_time)
  select 'L-RECON-4', id, 'completed', '11178', 'A', 'B', 1500, now() - interval '5 days' from public.customers where company_name = 'Recon Freight';

-- ── dry run: reports the two real matches, mutates nothing ──
select is((public.acct_reconcile_qbo_billing(true)->>'matched')::int, 2,
  'dry run finds both loads with a live QBO invoice (incl. the leading-zero ref)');
select is((public.acct_reconcile_qbo_billing(true)->>'linked')::int, 0,
  'dry run links nothing');
select is((select status::text from public.loads where load_number = 'L-RECON-1'), 'completed',
  'dry run leaves the load completed');

-- ── real run ──
select is((public.acct_reconcile_qbo_billing(false)->>'linked')::int, 2,
  'real run links the two matched loads');
select is((select status::text from public.loads where load_number = 'L-RECON-1'), 'billed',
  'matched load flips to billed');
select is(
  (select invoice_id from public.loads where load_number = 'L-RECON-1'),
  (select id from public.invoices where invoice_number = 'QBO-5001'),
  'load points at its QBO invoice');
select is((select status::text from public.loads where load_number = 'L-RECON-4'), 'billed',
  'leading-zero ref matched and billed (normalized)');
select is((select status::text from public.loads where load_number = 'L-RECON-2'), 'completed',
  'load with no QBO invoice stays completed');
select is((select status::text from public.loads where load_number = 'L-RECON-3'), 'completed',
  'load whose only QBO invoice is void stays completed');

-- ── idempotent + residual count ──
select is((public.acct_reconcile_qbo_billing(false)->>'matched')::int, 0,
  'second run finds nothing new (idempotent)');
select is((public.acct_reconcile_qbo_billing(false)->>'still_unbilled')::int, 2,
  'the two genuinely-unbilled loads remain on the list');
select ok((select invoice_id is null from public.loads where load_number = 'L-RECON-2'),
  'unmatched load keeps a null invoice_id');

-- ── authz: a dispatcher may not run it ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000d02"}', true);
select throws_ok(
  $$ select public.acct_reconcile_qbo_billing(true) $$,
  'Not enough permissions',
  'non-admin is refused');

select * from finish();
rollback;

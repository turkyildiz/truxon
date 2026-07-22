-- Review H-1: approved detention on a billed load must never silently strand.
-- (1) propose_detention_accessorials skips already-invoiced loads;
-- (2) if the race still lands one (billed between propose and approve), the
--     sentinel `stranded_accessorial` finding surfaces it as critical.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f90'::uuid, 'det@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f90';
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000f90","role":"authenticated"}', true);

insert into public.customers (company_name) values ('DETENTION TEST CO');

-- a billed load (invoice exists, load points at it)
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source)
select 'DT90-1', id, now(), now() + interval '30 days', 1500, 'sent', 'truxon'
  from public.customers where company_name = 'DETENTION TEST CO';
insert into public.loads (load_number, customer_id, status, rate, invoice_id)
select 'LD90-1', c.id, 'billed', 1500, i.id
  from public.customers c, public.invoices i
 where c.company_name = 'DETENTION TEST CO' and i.invoice_number = 'DT90-1';

-- (1) simulate the race: a proposal that landed on the billed load, approved
insert into public.load_accessorials (load_id, atype, stop_type, amount, minutes, detail, status, decided_at)
select id, 'detention', 'delivery', 375, 150, 'test dwell', 'approved', now()
  from public.loads where load_number = 'LD90-1';

select ok(exists(select 1 from public.load_accessorials a
                  join public.loads l on l.id = a.load_id
                 where l.load_number = 'LD90-1' and a.status = 'approved'
                   and l.invoice_id is not null),
  'setup: an approved accessorial sits on an already-billed load');

-- (2) sentinel surfaces it as critical with the remedy
select public.sentinel_scan();
select ok(exists(select 1 from public.trux_insights
                  where dedup_key like 'stranded_accessorial:%'
                    and severity = 'critical' and status <> 'resolved'
                    and title like '%375%'),
  'sentinel fires a critical stranded_accessorial finding');

-- (3) void-&-re-bill remedy actually frees it: voiding reopens the accessorial
select public.void_invoice((select id from public.invoices where invoice_number = 'DT90-1'));
select is(
  (select a.status from public.load_accessorials a
     join public.loads l on l.id = a.load_id where l.load_number = 'LD90-1'),
  'approved', 'after void the accessorial is still approved (collectable on re-bill)');
select ok((select invoice_id is null from public.loads where load_number = 'LD90-1'),
  'after void the load is re-billable (invoice link cleared)');

select * from finish();
rollback;

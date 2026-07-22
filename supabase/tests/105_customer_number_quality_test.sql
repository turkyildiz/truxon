-- Customer regulatory-number quality check (20260722010001): active customers
-- with a structurally-invalid USDOT (not 5-8 digits) or MC (not 5-7 digits) each
-- fire a per-customer data finding; fixing the value resolves it; do_not_use and
-- clean customers are never flagged.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000c1a11'::uuid, 'cnq@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000c1a11';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000c1a11"}', true);

insert into public.customers (company_name, usdot_number) values ('Bad DOT Co', '123');
insert into public.customers (company_name, mc_number) values ('Bad MC Co', 'MC-99');
insert into public.customers (company_name, usdot_number, mc_number) values ('Clean Carrier Co', '1234567', '654321');

select public.sentinel_scan();

select ok(exists(
  select 1 from public.trux_insights ti
    join public.customers c on ti.dedup_key = 'cust_dot_malformed:'||c.id
  where c.company_name = 'Bad DOT Co' and ti.status = 'open'),
  'a malformed USDOT (too short) is flagged open');

select ok(exists(
  select 1 from public.trux_insights ti
    join public.customers c on ti.dedup_key = 'cust_mc_malformed:'||c.id
  where c.company_name = 'Bad MC Co' and ti.status = 'open'),
  'a malformed MC (too short) is flagged open');

select ok(not exists(
  select 1 from public.trux_insights ti
    join public.customers c on (ti.dedup_key = 'cust_dot_malformed:'||c.id
                             or ti.dedup_key = 'cust_mc_malformed:'||c.id)
  where c.company_name = 'Clean Carrier Co'),
  'a customer with a valid 7-digit USDOT and 6-digit MC is not flagged');

-- fixing the value auto-resolves
update public.customers set usdot_number = '1234567' where company_name = 'Bad DOT Co';
select public.sentinel_scan();
select is((select ti.status from public.trux_insights ti
             join public.customers c on ti.dedup_key = 'cust_dot_malformed:'||c.id
            where c.company_name = 'Bad DOT Co'),
  'resolved', 'correcting the USDOT auto-resolves the finding');

-- do_not_use customers are excluded from the check
insert into public.customers (company_name, usdot_number, do_not_use) values ('Dead Co', '1', true);
select public.sentinel_scan();
select ok(not exists(
  select 1 from public.trux_insights ti
    join public.customers c on ti.dedup_key = 'cust_dot_malformed:'||c.id
  where c.company_name = 'Dead Co'),
  'do_not_use customers are not flagged');

select * from finish();
rollback;

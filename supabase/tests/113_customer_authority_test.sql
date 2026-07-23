-- customer-authority sentinel over customer_fmcsa_checks: revoked authority
-- fires critical, name drift warns, a clean check stays quiet.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000114'::uuid, 'auth@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000114';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000114"}', true);

insert into public.customers (company_name, mc_number, usdot_number) values
  ('Revoked Freight LLC', '111111', '1111111'),
  ('Renamed Logistics', '222222', '2222222'),
  ('Clean Carrier Inc', '333333', '3333333');

insert into public.customer_fmcsa_checks (customer_id, usdot, mc, legal_name, allowed_to_operate, oos_date, name_match) values
  ((select id from public.customers where company_name='Revoked Freight LLC'), '1111111', '111111', 'REVOKED FREIGHT LLC', 'N', current_date - 10, true),
  ((select id from public.customers where company_name='Renamed Logistics'), '2222222', '222222', 'SOMEBODY ELSE ENTIRELY INC', 'Y', null, false),
  ((select id from public.customers where company_name='Clean Carrier Inc'), '3333333', '333333', 'CLEAN CARRIER INC', 'Y', null, true);

select public.sentinel_scan();

select ok(exists (
  select 1 from public.trux_insights
   where dedup_key = 'cust_authority:' || (select id from public.customers where company_name='Revoked Freight LLC')
     and severity = 'critical' and category = 'compliance' and status <> 'resolved'),
  'revoked / out-of-service authority fires critical');
select ok(exists (
  select 1 from public.trux_insights
   where dedup_key = 'cust_fmcsa_drift:' || (select id from public.customers where company_name='Renamed Logistics')
     and severity = 'warn' and status <> 'resolved'),
  'FMCSA name drift warns');
select ok(not exists (
  select 1 from public.trux_insights
   where dedup_key like 'cust_authority:%' || (select id from public.customers where company_name='Clean Carrier Inc')
      or dedup_key = 'cust_fmcsa_drift:' || (select id from public.customers where company_name='Clean Carrier Inc')),
  'clean check stays quiet');

select * from finish();
rollback;

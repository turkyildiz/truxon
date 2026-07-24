-- R9 #130/#136: the onboarding checklist tells the truth item by item, and
-- prospects convert exactly once into real customers.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000175'::uuid, 'ob-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000175';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000175"}', true);

-- a half-set-up broker: contact yes, billing no, MC yes, unvetted, no docs
insert into public.customers (company_name, email, mc_number, payment_terms)
values ('Onboard Broker', 'ap@onboard.test', 'MC123456', 'Net 30');

create temp table ob as select public.customer_onboarding_report(
  (select id from public.customers where company_name='Onboard Broker')) as v;

select is((select (v->>'total')::int from ob), 7, 'seven checklist items');
select is((select (v->>'done')::int from ob), 3, 'contact + terms + MC pass; the rest honestly fail');
select is(
  (select x->>'ok' from ob, jsonb_array_elements(v->'items') x where x->>'item' = 'FMCSA vetted'),
  'false', 'unvetted broker shows FMCSA item red');

-- vet lands (watcher writes the row) → item flips green
insert into public.customer_fmcsa_checks (customer_id, allowed_to_operate, oos_date, name_match, legal_name)
select id, 'Y', null, true, 'ONBOARD BROKER LLC' from public.customers where company_name='Onboard Broker';
select is(
  (select x->>'ok' from public.customer_onboarding_report(
      (select id from public.customers where company_name='Onboard Broker')) r,
      jsonb_array_elements(r->'items') x where x->>'item' = 'FMCSA vetted'),
  'true', 'clean FMCSA check flips the item green');

-- #136 prospects
insert into public.prospects (company_name, contact_person, email, mc_number)
values ('Fresh Lead Logistics', 'Sam', 'sam@lead.test', 'MC999');

select is((select status from public.prospects where company_name='Fresh Lead Logistics'), 'new', 'prospect starts new');

create temp table conv as select public.convert_prospect(
  (select id from public.prospects where company_name='Fresh Lead Logistics')) as cid;

select is((select company_name from public.customers c join conv on c.id = conv.cid),
  'Fresh Lead Logistics', 'conversion creates the customer');
select is((select status from public.prospects where company_name='Fresh Lead Logistics'),
  'converted', 'prospect marked converted and linked');
select is(
  (select public.convert_prospect((select id from public.prospects where company_name='Fresh Lead Logistics'))),
  (select cid from conv), 'second convert returns the same customer, no duplicate');

-- driver refused
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000176'::uuid, 'ob-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000176';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000176"}', true);
select throws_ok($$ select public.convert_prospect(1) $$,
  'Not enough permissions', 'driver cannot convert prospects');

select * from finish();
rollback;

-- R9 #169: the insurance data room assembles carrier + safety + roster +
-- equipment, flags credential currency, and stays office-only.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000190'::uuid, 'idr-acct@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000190';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000191'::uuid, 'idr-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000191';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000190"}', true);

update public.company_settings set usdot_number = '3456789', company_name = 'Aida Logistics' where id = 1;
insert into public.drivers (full_name, status, date_of_birth, hire_date, license_expiration, medical_card_expiry)
values ('Current Carla', 'active', '1985-03-01', '2020-06-01', current_date + 200, current_date + 100),
       ('Lapsed Lou', 'active', '1978-09-01', '2019-01-01', current_date - 10, current_date + 50),
       ('Retired Rita', 'terminated', '1970-01-01', '2010-01-01', current_date + 300, current_date + 300);
insert into public.trucks (unit_number, year, make, model, vin, status, purchase_price)
values ('IDR-T', 2023, 'Kenworth', 'T680', '1XKID0000000001', 'available', 165000);
insert into public.trailers (unit_number, year, make, model, vin, status)
values ('IDR-TR', 2021, 'Wabash', 'DuraPlate', '1JJID0000000002', 'available');
insert into public.customers (company_name) values ('IDR Broker');
insert into public.loads (customer_id, rate, miles, empty_miles, status, delivery_time)
select id, 1000, 500, 50, 'completed', now() - interval '30 days' from public.customers where company_name = 'IDR Broker';

create temp table idr as select public.insurance_data_room(12) as v;

select is((select v->'carrier'->>'usdot' from idr), '3456789', 'carrier identity carried');
select is((select (v->'drivers'->>'active')::int from idr), 2, 'terminated driver excluded from roster');
select is((select (v->'equipment'->>'power_units')::int from idr), 1, 'power units counted');
select is((select (v->'equipment'->>'trailers')::int from idr), 1, 'trailers counted');
-- credential currency flag: Carla current, Lou lapsed on CDL
select is(
  (select x->>'credentials_current' from idr, jsonb_array_elements(v->'drivers'->'roster') x
    where x->>'name' = 'Lapsed Lou'),
  'false', 'expired CDL flips credentials_current to false');
select ok((select (v->'loss_experience'->>'exposure_miles')::numeric >= 550 from idr),
  'exposure miles fold loaded + empty from the window');

-- driver refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000191"}', true);
select throws_ok($$ select public.insurance_data_room(12) $$,
  'Not enough permissions', 'driver role is refused');

select * from finish();
rollback;

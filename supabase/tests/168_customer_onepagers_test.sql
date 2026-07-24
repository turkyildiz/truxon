-- R9 #134/#137: QBR quarters split correctly, payment speed is real, and the
-- detention profile measures GPS dwell honestly (unmeasured stops counted).
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000173'::uuid, 'op-acct@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000173';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000173"}', true);

insert into public.customers (company_name) values ('QBR Broker');
insert into public.trucks (unit_number) values ('QBR-T');

-- QBR fixtures anchored to quarter boundaries (robust on any run date):
-- current quarter: 2 loads at $1000+$1400 (miles 400 each); previous: 1 at $900 + 1 cancel
insert into public.loads (customer_id, rate, miles, status, created_at)
select c.id, x.rate, 400, x.st::public.load_status, x.at
  from public.customers c, (values
    (1000, 'completed', date_trunc('quarter', now()) + interval '1 day'),
    (1400, 'completed', date_trunc('quarter', now()) + interval '2 days'),
    (900,  'completed', date_trunc('quarter', now()) - interval '3 months' + interval '1 day'),
    (777,  'cancelled', date_trunc('quarter', now()) - interval '3 months' + interval '2 days')
  ) x(rate, st, at)
 where c.company_name = 'QBR Broker';

insert into public.invoices (invoice_number, customer_id, invoice_date, total, status, paid_at)
select 'QBR-INV-1', id, now() - interval '30 days', 1000, 'paid', now() - interval '20 days'
  from public.customers where company_name = 'QBR Broker';

create temp table qbr as select public.customer_qbr(
  (select id from public.customers where company_name='QBR Broker')) as v;

select is((select (v->'current'->>'loads_n')::int from qbr), 2, 'current quarter counts its two loads');
select is((select (v->'current'->>'revenue')::numeric from qbr), 2400.00, 'current-quarter revenue summed');
select is((select (v->'previous'->>'cancels')::int from qbr), 1, 'previous-quarter cancel counted, not in revenue');
select is((select (v->'payment'->>'avg_days_to_pay')::int from qbr), 10, 'payment speed measured from invoice to paid');
select is((select v->'top_lanes'->0->>'lane' from qbr), '?→?', 'ungeocoded lanes shown as ?, never invented');

-- #137: one pickup with GPS dwell 3.5h (90min over free), one stop unmeasured
insert into public.loads (customer_id, rate, miles, status, truck_id, pickup_address, pickup_time, pickup_lat, pickup_lon, created_at)
select c.id, 1200, 300, 'completed', t.id, 'Dock A, Toledo OH', now() - interval '5 days', 41.60, -83.50, now() - interval '6 days'
  from public.customers c, public.trucks t
 where c.company_name = 'QBR Broker' and t.unit_number = 'QBR-T';

insert into public.eld_location_history (id, truck_id, lat, lng, ts)
select gen_random_uuid(), t.id, 41.601, -83.501, x.at
  from public.trucks t, (values
    (now() - interval '5 days' - interval '60 minutes'),
    (now() - interval '5 days' + interval '150 minutes')
  ) x(at)
 where t.unit_number = 'QBR-T';

create temp table dp as select public.customer_detention_profile(
  (select id from public.customers where company_name='QBR Broker'), 180) as v;

select is((select (v->>'stops_measured')::int from dp), 1, 'exactly one stop has GPS dwell');
select is((select (v->>'avg_dwell_min')::int from dp), 210, '3.5h dwell measured from breadcrumbs');
select is((select (v->>'est_owed')::numeric from dp), 75.00, '90 min over free time at $50/h = $75');

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000174'::uuid, 'op-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000174';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000174"}', true);
select throws_ok($$ select public.customer_qbr(1) $$,
  'Not enough permissions', 'driver role is refused');

select * from finish();
rollback;

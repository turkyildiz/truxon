-- Trux Sentinel: the deterministic checks fire the right insights, dedup on
-- re-scan, auto-resolve when the condition clears, and acknowledge works.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d1'::uuid, 'sentinel@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000d1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000d1"}', true);

insert into public.customers (company_name) values ('SN Broker');
insert into public.drivers (full_name, status, license_expiration)
  values ('Expiring Ed', 'active', now()::date + 10);   -- license within 30 days
insert into public.trucks (unit_number) values ('S1');

-- A late load: delivery_time in the past, still in_transit.
insert into public.loads (customer_id, rate, miles, delivery_time, status, notes)
  select id, 2000, 500, now() - interval '2 days', 'pending', 'sn-late' from public.customers where company_name='SN Broker';
select set_config('app.load_rpc','1',true);
update public.loads set status='in_transit',
  driver_id=(select id from public.drivers where full_name='Expiring Ed'),
  truck_id=(select id from public.trucks where unit_number='S1')
 where notes='sn-late';
select set_config('app.load_rpc','',true);

-- A toll violation this week.
select public.import_toll_transactions(json_build_array(json_build_object(
  'toll_id','sn-v1','post_date_time', to_char(now() - interval '1 day','YYYY-MM-DD"T"HH24:MI:SS'),
  'vehicle_number','S1','toll_agency_name','IL Tollway','toll_agency_state','IL',
  'toll_charge',75.00,'toll_category','Violation','raw', json_build_object()))::jsonb);

-- ---------- scan ----------
select is((public.sentinel_scan()->>'open')::int >= 3, true, 'scan opens insights for the seeded problems');

select is(
  (select severity from public.trux_insights where dedup_key = 'late_load:'||(select id from public.loads where notes='sn-late')),
  'critical', 'a load 2 days late is critical'
);
select is(
  (select category from public.trux_insights where dedup_key = 'toll_violation:'||(select id from public.toll_transactions where toll_id='sn-v1')),
  'money', 'toll violation is a money-leak insight'
);
select is(
  (select category from public.trux_insights where dedup_key = 'license_exp:'||(select id from public.drivers where full_name='Expiring Ed')),
  'compliance', 'expiring license is a compliance insight'
);

-- ---------- dedup on re-scan ----------
select public.sentinel_scan();
select is(
  (select count(*)::int from public.trux_insights where dedup_key = 'late_load:'||(select id from public.loads where notes='sn-late')),
  1, 're-scanning does not duplicate an existing insight'
);

-- ---------- acknowledge ----------
select is(
  (public.acknowledge_insight((select id from public.trux_insights where dedup_key = 'toll_violation:'||(select id from public.toll_transactions where toll_id='sn-v1')))).status,
  'acknowledged', 'acknowledging an insight marks it acknowledged'
);

-- ---------- auto-resolve when the condition clears ----------
-- Deliver the late load; the late_load finding should stop firing → resolved.
select set_config('app.load_rpc','1',true);
update public.loads set status='delivered' where notes='sn-late';
select set_config('app.load_rpc','',true);
select public.sentinel_scan();
select is(
  (select status from public.trux_insights where dedup_key = 'late_load:'||(select id from public.loads where notes='sn-late')),
  'resolved', 'delivering the load auto-resolves the late insight'
);
-- The acknowledged toll violation is still within its 7-day window → stays.
select is(
  (select status from public.trux_insights where dedup_key = 'toll_violation:'||(select id from public.toll_transactions where toll_id='sn-v1')),
  'acknowledged', 'a still-firing acknowledged insight is not reset'
);

select * from finish();
rollback;

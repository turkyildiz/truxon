-- C-suite layer: company_scorecard figures, safety_summary rates, and the new
-- Sentinel safety + concentration insights.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000c5'::uuid, 'csuite@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000c5';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c5"}', true);

insert into public.customers (company_name) values ('CS Big'), ('CS Small');
insert into public.drivers (full_name, status, pay_per_mile) values ('CS Driver', 'active', 0.50);
insert into public.trucks (unit_number, year) values ('07', 2020);

-- Big = $8000 / 1000 loaded + 100 empty; Small = $2000 / 500 loaded.
insert into public.loads (customer_id, rate, miles, empty_miles, delivery_time, driver_id, notes)
  select (select id from public.customers where company_name='CS Big'), 8000, 1000, 100, '2026-07-10T10:00:00Z',
         (select id from public.drivers where full_name='CS Driver'), 'cs-big';
insert into public.loads (customer_id, rate, miles, empty_miles, delivery_time, driver_id, notes)
  select (select id from public.customers where company_name='CS Small'), 2000, 500, 0, '2026-07-11T10:00:00Z',
         (select id from public.drivers where full_name='CS Driver'), 'cs-small';
select set_config('app.load_rpc','1',true);
update public.loads set status='completed', truck_id=(select id from public.trucks where unit_number='07')
 where notes in ('cs-big','cs-small');
select set_config('app.load_rpc','',true);

-- 200 gallons of fuel for the fleet (1500 loaded mi / 200 = 7.5 mpg).
select public.import_fuel_transactions(json_build_array(json_build_object(
  'uuid','cs-f1','transaction_time','2026-07-09T08:00:00Z','status','Approved',
  'amount',700,'net_of_discount',700,'gallons',200,'vehicle_name','07','raw',json_build_object()))::jsonb);

-- ---------- company_scorecard ----------
select is((public.company_scorecard('2026-07-01','2026-08-01')->'financial'->>'revenue')::numeric, 10000.00::numeric, 'scorecard revenue');
select is((public.company_scorecard('2026-07-01','2026-08-01')->'operations'->>'fleet_mpg')::numeric, 7.50::numeric, 'scorecard fleet MPG (1500/200)');
select is((public.company_scorecard('2026-07-01','2026-08-01')->'operations'->>'empty_mile_pct')::numeric, 6.3::numeric, 'scorecard empty-mile % (100/1600)');
select is((public.company_scorecard('2026-07-01','2026-08-01')->'revenue'->>'active_customers')::int, 2, 'scorecard active customers');

-- ---------- safety ----------
insert into public.safety_events (event_type, event_date, driver_id, preventable, severity, description)
  values ('accident','2026-07-14',(select id from public.drivers where full_name='CS Driver'), true, 'critical', 'Rear-end at dock');
insert into public.safety_events (event_type, event_date, truck_id, out_of_service)
  values ('inspection','2026-07-12',(select id from public.trucks where unit_number='07'), true);
insert into public.safety_events (event_type, event_date, out_of_service) values ('inspection','2026-07-13', false);
insert into public.safety_events (event_type, event_date, claim_amount) values ('claim','2026-07-15', 10000);

select is((public.safety_summary('2026-07-01','2026-08-01')->>'accidents')::int, 1, 'safety: one accident');
select is((public.safety_summary('2026-07-01','2026-08-01')->>'out_of_service_rate_pct')::numeric, 50.0::numeric, 'safety: OOS rate 1 of 2 inspections');
select is((public.safety_summary('2026-07-01','2026-08-01')->>'accidents_per_million_miles')::numeric, 625.00::numeric, 'safety: accidents/million mi (1 / 1600 mi)');

-- ---------- scorecard: resurrected sections (Northstar night) ----------
select is((public.company_scorecard('2026-07-01','2026-08-01')->'safety'->>'accidents_in_window')::int, 1, 'scorecard safety: accident in window now captured');
select is((public.company_scorecard('2026-07-01','2026-08-01')->'safety'->>'preventable_accidents_in_window')::int, 1, 'scorecard safety: preventable accident captured');
-- detention/telematics present (zero here — no ELD seed), and no longer in not_captured
select ok(not (public.company_scorecard('2026-07-01','2026-08-01')->'not_captured' @> '["detention hours"]'::jsonb), 'detention no longer listed as not-captured');
-- sales pipeline folded into the scorecard; bids no longer 'not captured'
select isnt(public.company_scorecard('2026-07-01','2026-08-01')->'sales', null, 'scorecard carries a sales section');
select ok(not (public.company_scorecard('2026-07-01','2026-08-01')->'not_captured' @> '["bids/win-rate/pipeline"]'::jsonb), 'bids/win-rate no longer not-captured');

-- ---------- sentinel v2 ----------
select public.sentinel_scan();
select is(
  (select severity from public.trux_insights where dedup_key = 'accident:'||(select id from public.safety_events where description='Rear-end at dock')),
  'critical', 'a preventable accident raises a critical insight'
);
select ok(
  exists(select 1 from public.trux_insights where dedup_key = 'concentration:'||(select id from public.customers where company_name='CS Big')),
  'customer concentration (CS Big = 80% of revenue) raises an insight'
);

select * from finish();
rollback;

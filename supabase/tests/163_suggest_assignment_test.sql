-- R9 #115/#116: assignment suggester — nearest free driver ranks first with a
-- priced deadhead, busy drivers sink with their free-at time, positionless
-- drivers say null (never 0), lane history counts, and drivers can't call it.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000163'::uuid, 'sa-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000163';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000163"}', true);

insert into public.customers (company_name) values ('SA Broker');
insert into public.trucks (unit_number) values ('SA-1'), ('SA-2');
insert into public.drivers (full_name, status) values
  ('Near Driver', 'active'), ('Busy Driver', 'active'),
  ('Ghost Driver', 'active'), ('Retired Driver', 'inactive');

-- Near Driver delivered 2 days ago right by the pickup (41.0,-84.0), and has
-- run this OH->TN lane before
insert into public.loads (customer_id, rate, miles, status, driver_id, truck_id,
                          pickup_state, delivery_state, delivery_lat, delivery_lon, delivery_time, pickup_time)
values ((select id from public.customers where company_name='SA Broker'), 1000, 300, 'completed',
        (select id from public.drivers where full_name='Near Driver'),
        (select id from public.trucks where unit_number='SA-1'),
        'OH', 'TN', 41.0, -84.0, now() - interval '2 days', now() - interval '3 days');

-- Busy Driver is mid-load, delivering after our pickup time
insert into public.loads (customer_id, rate, miles, status, driver_id, truck_id,
                          load_number, delivery_time, pickup_time)
values ((select id from public.customers where company_name='SA Broker'), 900, 250, 'assigned',
        (select id from public.drivers where full_name='Busy Driver'),
        (select id from public.trucks where unit_number='SA-2'),
        'SA-BUSY-1', now() + interval '3 days', now() - interval '1 day');

create temp table sa as
select public.suggest_assignment(41.1, -84.1, now() + interval '1 day', 'OH', 'TN') as v;

-- 1. inactive drivers never show
select is((select jsonb_array_length(v->'suggestions') from sa), 3,
  'three active drivers ranked, retired one absent');
-- 2. nearest free driver ranks first
select is((select v->'suggestions'->0->>'driver' from sa), 'Near Driver',
  'free driver with a known nearby position ranks first');
-- 3. deadhead is priced or at least measured
select ok((select (v->'suggestions'->0->>'deadhead_miles')::numeric between 1 and 60 from sa),
  'deadhead miles computed from last delivery position (~10 mi x1.2)');
-- 4. lane history counted
select is((select (v->'suggestions'->0->>'lane_runs')::int from sa), 1,
  'prior OH->TN run counted as lane history');
-- 5. busy driver flagged with the load holding them
select is((select s->>'on_load' from sa, jsonb_array_elements(v->'suggestions') s
            where s->>'driver' = 'Busy Driver'), 'SA-BUSY-1',
  'mid-load driver carries the load number holding them');
-- 6. positionless driver reports null deadhead, not zero
select ok((select s->'deadhead_miles' = 'null'::jsonb from sa, jsonb_array_elements(v->'suggestions') s
            where s->>'driver' = 'Ghost Driver'),
  'no known position means null deadhead, never a fake 0');
-- 7. busy drivers sink below free ones
select isnt((select v->'suggestions'->0->>'driver' from sa), 'Busy Driver',
  'busy driver never ranks first');

-- 8. drivers cannot call the suggester
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000164'::uuid, 'sa-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000164';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000164"}', true);
select throws_ok($$ select public.suggest_assignment(41.0, -84.0) $$,
  'Not enough permissions', 'driver role is refused');

select * from finish();
rollback;

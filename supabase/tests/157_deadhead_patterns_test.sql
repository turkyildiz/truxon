-- Deadhead patterns: consecutive loads per truck yield a repositioning hop.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000157'::uuid, 'dh@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000157';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000157"}', true);

insert into public.customers (company_name) values ('DH Broker');
insert into public.trucks (unit_number) values ('DH-T');
-- load 1 delivers in OH; load 2 picks up 2 days later with 150 booked empty miles
insert into public.loads (customer_id, rate, miles, status, truck_id, delivery_state, delivery_time, delivery_lat, delivery_lon, pickup_time)
values ((select id from public.customers where company_name='DH Broker'), 1000, 400, 'completed',
        (select id from public.trucks where unit_number='DH-T'), 'OH', now() - interval '10 days', 40.0, -83.0, now() - interval '11 days');
insert into public.loads (customer_id, rate, miles, status, truck_id, empty_miles, pickup_state, pickup_time, pickup_lat, pickup_lon, delivery_time)
values ((select id from public.customers where company_name='DH Broker'), 1200, 500, 'completed',
        (select id from public.trucks where unit_number='DH-T'), 150, 'IN', now() - interval '8 days', 40.5, -85.0, now() - interval '7 days');

select is((public.deadhead_patterns(120)->>'hops_measured')::int, 1, 'one hop measured');
select is((public.deadhead_patterns(120)->>'avg_deadhead_miles')::numeric, 150::numeric,
  'booked empty miles win over the straight-line estimate');

select * from finish();
rollback;

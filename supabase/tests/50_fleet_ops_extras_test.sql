-- Fleet ops extras: deadhead/dispatch, loads/day, miles/day; metrics flip live.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f50'::uuid, 'ops@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f50';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f50"}', true);

insert into public.customers (company_name) values ('Ops Broker');
insert into public.drivers (full_name, status) values ('Ops Driver', 'active');

-- 2 loads: 1000+1500 loaded, 200+300 empty. total_mi=3000, empty=500, loads=2.
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, empty_miles, driver_id)
  select 'OP-1', c.id, 'billed', now() - interval '3 days', 2000, 1000, 200, d.id
    from public.customers c, public.drivers d where c.company_name='Ops Broker' and d.full_name='Ops Driver';
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, empty_miles, driver_id)
  select 'OP-2', c.id, 'billed', now() - interval '4 days', 3000, 1500, 300, d.id
    from public.customers c, public.drivers d where c.company_name='Ops Broker' and d.full_name='Ops Driver';

-- deadhead per dispatch = 500/2 = 250
select is((public.fleet_ops_extras(now() - interval '30 days', now())->>'deadhead_miles_per_dispatch')::numeric, 250::numeric, 'deadhead miles per dispatch = empty ÷ loads');
select is((public.fleet_ops_extras(now() - interval '30 days', now())->>'working_drivers')::int, 1, 'distinct working drivers counted');
select is((select status from public.playbook_metrics where number=206), 'live', 'deadhead metric is live');
select is((select status from public.playbook_metrics where number=286), 'live', 'miles-per-day metric is live');

select * from finish();
rollback;

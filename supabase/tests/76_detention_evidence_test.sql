-- R3 #5: proposed detention banks its ELD dwell proof so the exhibit outlives
-- the 2-day breadcrumb retention.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f7e'::uuid, 'ev@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f7e';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f7e"}', true);

insert into public.customers (company_name) values ('Evidence Broker');
insert into public.trucks (unit_number, status) values ('EV1', 'available');
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, truck_id,
                          delivery_lat, delivery_lon, delivery_state)
  select 'EV-1', c.id, 'completed', now() - interval '25 hours', 2000, 600, t.id, 40.0, -80.0, 'PA'
    from public.customers c, public.trucks t
   where c.company_name = 'Evidence Broker' and t.unit_number = 'EV1';
insert into public.eld_location_history (id, truck_id, lat, lng, ts)
  select gen_random_uuid(), (select id from public.trucks where unit_number = 'EV1'),
         40.0, -80.0, now() - interval '25 hours' + make_interval(mins => g * 60)
  from generate_series(0, 4) g;

select ok(public.propose_detention_accessorials() >= 1, 'detention proposed');

select is(
  ((select evidence->>'dwell_min' from public.load_accessorials
     where load_id = (select id from public.loads where load_number = 'EV-1')))::int,
  240, 'evidence banks the dwell minutes');
select is(
  ((select evidence->>'detention_min' from public.load_accessorials
     where load_id = (select id from public.loads where load_number = 'EV-1')))::int,
  120, 'evidence banks the billable overage');
select ok(
  (select (evidence->>'arrival') is not null and (evidence->>'departure') is not null
     from public.load_accessorials
    where load_id = (select id from public.loads where load_number = 'EV-1')),
  'evidence banks the ELD arrival and departure timestamps');

select * from finish();
rollback;

-- Stop dwell: average ELD dwell at shipper vs consignee; metrics #229/#230 flip live.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f49'::uuid, 'dwell@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f49';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f49"}', true);

insert into public.customers (company_name) values ('Dwell Broker');
insert into public.trucks (unit_number, status) values ('DW1', 'available');

-- One load: pickup at (40,-80) with a 3h dwell, delivery at (34,-118) with a 4h dwell.
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, truck_id,
                          pickup_time, pickup_lat, pickup_lon, delivery_lat, delivery_lon)
  select 'DW-A', c.id, 'billed', now() - interval '20 hours', 2000, 1400, t.id,
         now() - interval '40 hours', 40.0, -80.0, 34.0, -118.0
    from public.customers c, public.trucks t where c.company_name='Dwell Broker' and t.unit_number='DW1';

-- pickup breadcrumbs: 0..3h (4 points, 1h apart) at the pickup coords
insert into public.eld_location_history (id, truck_id, lat, lng, ts)
  select ('00000000-0000-4000-8000-0000000002'||lpad(g::text,2,'0'))::uuid,
         (select id from public.trucks where unit_number='DW1'), 40.0, -80.0,
         now() - interval '40 hours' + make_interval(mins => g*60)
  from generate_series(0,3) g;
-- delivery breadcrumbs: 0..4h at the delivery coords
insert into public.eld_location_history (id, truck_id, lat, lng, ts)
  select ('00000000-0000-4000-8000-0000000003'||lpad(g::text,2,'0'))::uuid,
         (select id from public.trucks where unit_number='DW1'), 34.0, -118.0,
         now() - interval '20 hours' + make_interval(mins => g*60)
  from generate_series(0,4) g;

select is((public.stop_dwell_summary()->>'avg_dwell_hours_shipper')::numeric, 3.0::numeric, 'avg dwell at shipper (pickup) = 3h');
select is((public.stop_dwell_summary()->>'avg_dwell_hours_consignee')::numeric, 4.0::numeric, 'avg dwell at consignee (delivery) = 4h');
select is((select status from public.playbook_metrics where number=229), 'live', 'dwell-at-shipper metric is live');
select is((select status from public.playbook_metrics where number=230), 'live', 'dwell-at-consignee metric is live');

select * from finish();
rollback;

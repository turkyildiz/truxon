-- R4 #8: nearest open pickup ranks first; assigned/ungeocodable loads excluded.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f86'::uuid, 'nl@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000f86';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f86"}', true);

insert into public.customers (company_name) values ('NextLoad Broker');

-- delivered in Columbus OH (40.0, -83.0)
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles,
                          delivery_lat, delivery_lon)
select 'NL-DONE', id, 'completed', now() - interval '1 hour', 2000, 500, 40.0, -83.0
  from public.customers where company_name = 'NextLoad Broker';

-- open pickups: Cincinnati (~100 mi), Chicago (~275 mi), plus one already assigned
insert into public.loads (load_number, customer_id, status, rate, miles, pickup_lat, pickup_lon,
                          pickup_address, pickup_state)
select v.ln, c.id, 'pending', v.rate, v.mi, v.plat, v.plon, v.addr, v.st
  from public.customers c,
       (values ('NL-CIN', 1500::numeric, 400::numeric, 39.10, -84.51, 'Cincinnati OH', 'OH'),
               ('NL-CHI', 2500, 700, 41.88, -87.63, 'Chicago IL', 'IL')) as v(ln, rate, mi, plat, plon, addr, st)
 where c.company_name = 'NextLoad Broker';

select is((select s.load_number from public.next_load_suggestions(
  (select id from public.loads where load_number = 'NL-DONE')) s limit 1),
  'NL-CIN', 'nearest pickup ranks first');
select cmp_ok((select s.deadhead_miles from public.next_load_suggestions(
  (select id from public.loads where load_number = 'NL-DONE')) s limit 1),
  '<', 150::numeric, 'Cincinnati deadhead is sane straight-line miles');
select is((select count(*)::int from public.next_load_suggestions(
  (select id from public.loads where load_number = 'NL-DONE'))),
  2, 'both open geocoded pickups suggested, nothing else');

select * from finish();
rollback;

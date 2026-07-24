-- R9 #160: human edits leave a diff line; robots and noise columns don't.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000183'::uuid, 'ua-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000183';

insert into public.customers (company_name) values ('Audit Broker');
insert into public.loads (customer_id, rate, miles, status)
select id, 1000, 300, 'pending' from public.customers where company_name='Audit Broker';

-- robot update (no auth.uid()): silent
update public.loads set rate = 1100 where rate = 1000;
select is((select count(*) from public.activity_log where action = 'updated'), 0::bigint,
  'service/robot updates (no session) log nothing');

-- human update: one compact diff line with the field and both values
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000183"}', true);
update public.loads set rate = 1200, miles = 350 where rate = 1100;
select is((select count(*) from public.activity_log where action = 'updated'), 1::bigint,
  'human edit writes exactly one audit line');
select ok((select detail like '%rate: 1100.00 → 1200.00%' from public.activity_log where action='updated'),
  'diff names the field with old → new');
select ok((select detail like '%miles%' from public.activity_log where action='updated'),
  'multi-field edit lists every changed field');

-- noise columns (geocode stamps) alone: silent even for humans
update public.loads set pickup_lat = 41.0, pickup_lon = -83.0, pickup_state = 'OH' where miles = 350;
select is((select count(*) from public.activity_log where action = 'updated'), 1::bigint,
  'geocode-stamp-only updates are not audit noise');

select * from finish();
rollback;

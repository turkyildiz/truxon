-- Positive-form role gates (20260723001001): under pgTAP auth.role() is NULL, and
-- the old negated idiom (auth.role() <> 'service_role' and ...) evaluated NULL and
-- silently passed for ANY signed-in role. The positive form must actually reject
-- non-office roles here, and the office/admin path must still work.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000149'::uuid, 'gate-driver@test.local'),
  ('00000000-0000-4000-8000-000000000150'::uuid, 'gate-admin@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000149';
update public.profiles set role = 'admin'  where id = '00000000-0000-4000-8000-000000000150';

-- a driver (auth.role() NULL, my_role() = 'driver') is rejected by office-gated functions
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000149"}', true);
select throws_ok('select public.sales_pipeline(now() - interval ''7 days'', now())',
  'P0001', 'Not enough permissions', 'driver cannot read sales_pipeline');
select throws_ok('select public.sentinel_scan()',
  'P0001', 'Not enough permissions', 'driver cannot run sentinel_scan');
select throws_ok('select public.security_console()',
  'P0001', 'Not enough permissions', 'driver cannot read security_console');

-- the admin path still passes with sub-only claims (my_role() side of the gate)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000150"}', true);
select lives_ok('select public.sentinel_open_summary()', 'admin passes the positive gate');

-- detention_events_core (20260723001002) is internal-only: app roles cannot execute it
select ok(not has_function_privilege('anon',
  'public.detention_events_core(integer, integer, numeric, numeric)', 'execute'),
  'anon cannot execute detention_events_core');
select ok(not has_function_privilege('authenticated',
  'public.detention_events_core(integer, integer, numeric, numeric)', 'execute'),
  'authenticated cannot execute detention_events_core');

select * from finish();
rollback;

-- R9 #127/#133: share links are bounded capabilities — office mints them
-- (idempotently), drivers can't, feedback is one-per-link, and neither table
-- leaks to the driver role.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000171'::uuid, 'ls-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000171';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000172'::uuid, 'ls-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000172';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000171"}', true);

insert into public.customers (company_name) values ('LS Broker');
insert into public.loads (customer_id, rate, miles, status)
select id, 1500, 350, 'delivered' from public.customers where company_name = 'LS Broker';

-- 1-3. mint works, is idempotent, and the token is long enough to matter
select ok((select length(public.create_load_share(l.id)) >= 32 from public.loads l limit 1),
  'dispatcher mints a >=32-char token');
select is(
  (select public.create_load_share(l.id) from public.loads l limit 1),
  (select public.create_load_share(l.id) from public.loads l limit 1),
  're-sharing the same load reuses the live token');
select is((select count(*) from public.load_share_links), 1::bigint,
  'idempotent mint leaves exactly one link');

-- 4. unknown load refused
select throws_ok($$ select public.create_load_share(999999) $$,
  'Load not found', 'unknown load refused');

-- 5. feedback is one-per-link (unique share_id)
insert into public.load_feedback (load_id, share_id, rating)
select s.load_id, s.id, 'up' from public.load_share_links s limit 1;
select throws_like($$
  insert into public.load_feedback (load_id, share_id, rating)
  select s.load_id, s.id, 'down' from public.load_share_links s limit 1
$$, '%duplicate key%', 'second thumbs on the same link bounces');

-- 6-8. driver role: can't mint, can't read links, can't read feedback
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000172"}', true);
select throws_ok($$ select public.create_load_share(1) $$,
  'Not enough permissions', 'driver cannot mint share links');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000172"}', true);
select is((select count(*) from public.load_share_links), 0::bigint, 'driver sees zero share links');
select is((select count(*) from public.load_feedback), 0::bigint, 'driver sees zero feedback rows');
reset role;

select * from finish();
rollback;

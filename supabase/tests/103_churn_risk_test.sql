-- Customer churn-risk sentinel (20260722009005): a regular broker gone silent
-- past 2x its cadence (and >45d) fires; an actively-shipping broker stays quiet;
-- a new load resolves it.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000c501'::uuid, 'ch@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000c501';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000c501"}', true);

insert into public.customers (company_name) values ('Quiet Broker'), ('Active Broker');
-- Quiet: 5 loads 97–125 days ago, nothing since (~36d cadence, silent ~97d)
insert into public.loads (load_number, customer_id, status, rate, miles, created_at)
select 'Q-' || g, id, 'completed', 1000, 300, now() - make_interval(days => 90 + g*7)
  from public.customers, generate_series(1,5) g where company_name = 'Quiet Broker';
-- Active: 5 loads incl. one 10 days ago
insert into public.loads (load_number, customer_id, status, rate, miles, created_at)
select 'A-' || g, id, 'completed', 1000, 300, now() - make_interval(days => g*10)
  from public.customers, generate_series(1,5) g where company_name = 'Active Broker';

select public.sentinel_scan();
select ok(exists(select 1 from public.trux_insights ti join public.customers c on c.id = ti.entity_id
                  where ti.dedup_key like 'customer_quiet:%' and c.company_name = 'Quiet Broker' and ti.status = 'open'),
  'a silent regular broker fires the churn-risk finding');
select ok(not exists(select 1 from public.trux_insights ti join public.customers c on c.id = ti.entity_id
                      where ti.dedup_key like 'customer_quiet:%' and c.company_name = 'Active Broker'),
  'an actively-shipping broker does not fire');

-- a fresh load → resolves
insert into public.loads (load_number, customer_id, status, rate, miles, created_at)
select 'Q-NEW', id, 'assigned', 1000, 300, now() from public.customers where company_name = 'Quiet Broker';
select public.sentinel_scan();
select is((select ti.status from public.trux_insights ti join public.customers c on c.id = ti.entity_id
            where ti.dedup_key like 'customer_quiet:%' and c.company_name = 'Quiet Broker'),
  'resolved', 'a new booking auto-resolves the churn finding');

-- prefix present (structural)
select ok((select public.sentinel_scan() is not null), 're-scan runs clean');

select * from finish();
rollback;

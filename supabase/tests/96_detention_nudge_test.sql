-- Detention review-queue nudge (20260722008001): a proposed accessorial older
-- than 48h fires a standing cash finding; deciding it auto-resolves on the
-- next scan. Fresh proposals (<48h) stay quiet.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000d96'::uuid, 'nudge@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000d96';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000d96"}', true);

insert into public.customers (company_name) values ('Nudge Broker');
insert into public.loads (load_number, customer_id, status, rate, miles)
select 'NUDGE-1', id, 'completed', 1000, 300 from public.customers where company_name = 'Nudge Broker';

-- fresh proposal (<48h) → no finding
insert into public.load_accessorials (load_id, atype, stop_type, amount, minutes, detail, status)
select id, 'detention', 'delivery', 200, 120, 'fresh', 'proposed' from public.loads where load_number = 'NUDGE-1';
select ok((select public.sentinel_scan() is not null), 'scan runs');
select ok(
  not exists(select 1 from public.trux_insights where dedup_key = 'accessorial_review_queue' and status = 'open'),
  'fresh proposal (<48h) stays quiet');

-- age it past 48h → finding fires
update public.load_accessorials set created_at = now() - interval '3 days' where detail = 'fresh';
select public.sentinel_scan();
select ok(
  exists(select 1 from public.trux_insights where dedup_key = 'accessorial_review_queue' and status = 'open'),
  'aged proposal fires the review-queue nudge');

-- decide it → auto-resolves
update public.load_accessorials set status = 'approved' where detail = 'fresh';
select public.sentinel_scan();
select is(
  (select status from public.trux_insights where dedup_key = 'accessorial_review_queue'),
  'resolved', 'deciding the proposal auto-resolves the nudge');

select * from finish();
rollback;

-- Anomaly narrative: young history states readiness; a real mover reads as a
-- sentence with direction.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000152'::uuid, 'an@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000152';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000152"}', true);

-- two weeks of snapshots for one metric: 100 -> 150 (up 50% WoW)
insert into public.metric_snapshots (metric_key, captured_on, value)
select 'an_test_metric', d::date, case when d::date > current_date - 7 then 150 else 100 end
  from generate_series(current_date - 13, current_date, interval '1 day') d;

select ok((public.anomaly_digest(15)->>'ready')::boolean, 'two banked weeks make it ready');
select ok((public.anomaly_digest(15)->>'text') ilike '%an test metric up 50%%%',
  'the mover reads as a sentence with direction');

select * from finish();
rollback;

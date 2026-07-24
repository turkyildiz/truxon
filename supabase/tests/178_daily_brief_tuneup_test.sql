-- R9 #176: the daily brief spreads across categories — one noisy category can
-- no longer crowd out other signals, criticals always surface, and snoozed
-- items stay out.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000194'::uuid, 'db-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000194';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000194"}', true);

-- six ops warnings (noisy category) + one lone compliance warning +
-- one money critical + one snoozed maintenance warning
insert into public.trux_insights (dedup_key, category, severity, title, detail, last_seen, status) values
  ('det:1','ops','warn','Detention 1','',now() - interval '1 min','open'),
  ('det:2','ops','warn','Detention 2','',now() - interval '2 min','open'),
  ('det:3','ops','warn','Detention 3','',now() - interval '3 min','open'),
  ('det:4','ops','warn','Detention 4','',now() - interval '4 min','open'),
  ('det:5','ops','warn','Detention 5','',now() - interval '5 min','open'),
  ('det:6','ops','warn','Detention 6','',now() - interval '6 min','open'),
  ('fuel:1','compliance','warn','Fuel theft flag','',now() - interval '10 min','open'),
  ('money:1','money','critical','Money path locked','',now() - interval '20 min','open'),
  ('snz:1','maintenance','warn','Snoozed safety','',now(),'open');
update public.trux_insights set snoozed_until = now() + interval '1 day' where dedup_key = 'snz:1';

create temp table b as select public.sentinel_open_summary() as v;

-- 1. the critical is present and ordered first
select is((select v->'top'->0->>'title' from b), 'Money path locked',
  'the critical leads the brief');
-- 2. detention is capped at 2 in the top list (was up to 6)
select is((select count(*) from b, jsonb_array_elements(v->'top') t
            where t->>'title' like 'Detention %'), 2::bigint,
  'a noisy category contributes at most two items');
-- 3. the lone fuel warning survives (would have been buried before)
select is((select count(*) from b, jsonb_array_elements(v->'top') t
            where t->>'title' = 'Fuel theft flag'), 1::bigint,
  'the diverse spread keeps the single fuel warning visible');
-- 4. snoozed item never appears
select is((select count(*) from b, jsonb_array_elements(v->'top') t
            where t->>'title' = 'Snoozed safety'), 0::bigint,
  'snoozed insights stay out of the brief');
-- 5. counts still honest (8 live open: 6 detention + 1 fuel + 1 critical)
select is((select (v->>'open')::int from b), 8, 'open count excludes the snoozed one');

select * from finish();
rollback;

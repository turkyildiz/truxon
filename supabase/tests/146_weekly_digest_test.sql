-- Weekly digest: groups by category with critical-first samples.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000147'::uuid, 'wd@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000147';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000147"}', true);

insert into public.trux_insights (dedup_key, category, severity, title, detail, entity_type, status) values
  ('wd1', 'money', 'critical', 'WD crit title', 'x', '', 'open'),
  ('wd2', 'money', 'warn', 'WD warn title', 'x', '', 'open'),
  ('wd3', 'ops', 'info', 'WD ops title', 'x', '', 'open');

select is(
  (select g->>'sample' from jsonb_array_elements(public.sentinel_weekly_digest()->'groups') g
    where g->>'category' = 'money'),
  'WD crit title', 'critical leads the category sample');
select ok((public.sentinel_weekly_digest()->>'text') like '%money: 2 open (1 critical)%',
  'text block carries grouped counts');

select * from finish();
rollback;

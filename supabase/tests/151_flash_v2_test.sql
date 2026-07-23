-- Weekly flash v2: pricing + DOT-readiness lines present, snooze-aware alerts.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000151'::uuid, 'fl@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000151';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000151"}', true);

select ok(public.weekly_flash(0) ? 'pricing', 'pricing-discipline line present');
select ok((public.weekly_flash(0)->'dot_readiness'->>'cdl') like '%/%', 'DOT readiness line reads have/want');

insert into public.trux_insights (dedup_key, category, severity, title, detail, entity_type, status, snoozed_until)
values ('fl-snoozed', 'ops', 'critical', 'snoozed crit', 'x', '', 'open', now() + interval '7 days');
select is((public.weekly_flash(0)->'sentinel'->>'critical')::int, 0, 'snoozed criticals stay out of the flash');

select * from finish();
rollback;

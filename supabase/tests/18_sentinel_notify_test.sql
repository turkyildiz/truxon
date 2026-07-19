-- Sentinel delivery: take_alerts returns each open critical once (stamping it
-- notified), the summary counts open items, and a reopen re-arms the alert.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000a01'::uuid, 'sent@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000a01';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000a01"}', true);

insert into public.trux_insights (dedup_key, category, severity, title, detail) values
  ('t_crit', 'cash', 'critical', 'BigCo is 95 days overdue', '$40k past 90'),
  ('t_warn', 'ops',  'warn',     'Load 7 is late', 'due earlier');

-- first take returns only the critical, and marks it notified
select is((select count(*)::int from public.sentinel_take_alerts()), 1, 'take_alerts returns the one open critical');
select ok((select notified_at is not null from public.trux_insights where dedup_key='t_crit'), 'critical is stamped notified');
-- second take returns nothing (already notified)
select is((select count(*)::int from public.sentinel_take_alerts()), 0, 'take_alerts does not re-push a notified critical');

-- summary counts open items
select is((public.sentinel_open_summary()->>'open')::int, 2, 'summary counts 2 open');

-- a recurrence: resolve then re-open clears notified, so it alerts again
update public.trux_insights set status='resolved', resolved_at=now() where dedup_key='t_crit';
update public.trux_insights set status='open' where dedup_key='t_crit';
select is((select count(*)::int from public.sentinel_take_alerts()), 1, 'a reopened critical re-arms and alerts again');

select * from finish();
rollback;

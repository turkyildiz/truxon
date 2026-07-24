-- R9 #174/#175: report builder + scheduling — catalog lists trended metrics,
-- render pulls latest+prior for a WoW delta, due-detection respects cadence
-- and recipients, and RLS keeps reports to their owner/admins.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000192'::uuid, 'sr-acct@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000192';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000193'::uuid, 'sr-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000193';

-- trend store: one metric moved 100 → 120 over the last week
insert into public.metric_snapshots (metric_key, captured_on, value) values
  ('revenue.week', current_date, 120),
  ('revenue.week', current_date - 8, 100),
  ('fleet.utilization_pct', current_date, 74);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000192"}', true);

-- 1. catalog offers the trended keys with their latest values
select ok((select public.report_metric_catalog()->'metrics' @> '[{"metric_key":"revenue.week","value":120}]'::jsonb),
  'catalog lists a trended metric with its freshest value');

-- build a saved report
insert into public.saved_reports (name, metric_keys, schedule, recipients)
values ('Weekly ops', array['revenue.week','fleet.utilization_pct'], 'weekly', array['owner@aida.test']);

-- 2-4. render: latest value + WoW delta source
select is((select jsonb_array_length((public.render_saved_report(
    (select id from public.saved_reports where name='Weekly ops')))->'rows')), 2,
  'report renders a row per picked metric');
select is((select (r->>'value')::numeric from
    public.render_saved_report((select id from public.saved_reports where name='Weekly ops')) rr,
    jsonb_array_elements(rr->'rows') r where r->>'metric_key' = 'revenue.week'), 120::numeric,
  'latest value surfaced');
select is((select (r->>'prior')::numeric from
    public.render_saved_report((select id from public.saved_reports where name='Weekly ops')) rr,
    jsonb_array_elements(rr->'rows') r where r->>'metric_key' = 'revenue.week'), 100::numeric,
  'prior-week value surfaced for the delta');

-- 5. RLS: another office user can read, a driver cannot even see it
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000193"}', true);
select is((select count(*) from public.saved_reports), 0::bigint, 'driver sees no saved reports');
reset role;

-- 6-8. due detection (service role): weekly + recipients + never-sent = due
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is((select jsonb_array_length(public.due_scheduled_reports())), 1, 'the weekly report is due');
-- marking sent removes it from the due set
select public.mark_report_sent((select id from public.saved_reports where name='Weekly ops'));
select is((select jsonb_array_length(public.due_scheduled_reports())), 0, 'a just-sent report is no longer due');
-- a report with no recipients is never due
update public.saved_reports set last_sent_at = null, recipients = '{}' where name='Weekly ops';
select is((select jsonb_array_length(public.due_scheduled_reports())), 0, 'no recipients means never due');

-- 9. driver cannot read the catalog
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000193"}', true);
select throws_ok($$ select public.report_metric_catalog() $$,
  'Not enough permissions', 'driver is refused the metric catalog');

select * from finish();
rollback;

-- R9 #174/#175: custom report builder lite + scheduling. A report is a named
-- pick-list of metric keys drawn from the nightly metric_snapshots trend
-- store (so no new numbers are invented — the builder can only surface what
-- the app already trends). A report can be scheduled weekly; a Monday-07:00
-- cron renders the due ones and emails them via the report-send edge function.
create table if not exists public.saved_reports (
  id bigserial primary key,
  name text not null check (length(trim(name)) between 1 and 80),
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  metric_keys text[] not null default '{}',
  schedule text not null default 'none' check (schedule in ('none','weekly')),
  recipients text[] not null default '{}',
  is_active boolean not null default true,
  last_sent_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.saved_reports enable row level security;
revoke all on table public.saved_reports from anon, authenticated;
grant select, insert, update, delete on public.saved_reports to authenticated;
-- owner manages their own; admins see/manage all; office roles can read
drop policy if exists sr_select on public.saved_reports;
create policy sr_select on public.saved_reports
  for select to authenticated
  using (owner_id = auth.uid() or public.my_role() in ('admin','accountant','dispatcher'));
drop policy if exists sr_insert on public.saved_reports;
create policy sr_insert on public.saved_reports
  for insert to authenticated
  with check (owner_id = auth.uid() and public.my_role() in ('admin','accountant','dispatcher'));
drop policy if exists sr_modify on public.saved_reports;
create policy sr_modify on public.saved_reports
  for update to authenticated
  using (owner_id = auth.uid() or public.my_role() = 'admin')
  with check (owner_id = auth.uid() or public.my_role() = 'admin');
drop policy if exists sr_delete on public.saved_reports;
create policy sr_delete on public.saved_reports
  for delete to authenticated
  using (owner_id = auth.uid() or public.my_role() = 'admin');
insert into app_private.security_baseline (kind, item) values
  ('grant', 'authenticated saved_reports SELECT'),
  ('grant', 'authenticated saved_reports INSERT'),
  ('grant', 'authenticated saved_reports UPDATE'),
  ('grant', 'authenticated saved_reports DELETE')
on conflict do nothing;

-- Pickable metrics: every key the nightly snapshot trends, with its freshest
-- value so the builder can preview as you pick.
create or replace function public.report_metric_catalog()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'metric_key', latest.metric_key, 'value', latest.value, 'captured_on', latest.captured_on)
      order by latest.metric_key), '[]'::jsonb) into v
  from (
    select distinct on (metric_key) metric_key, value, captured_on
      from metric_snapshots
     order by metric_key, captured_on desc
  ) latest;
  return jsonb_build_object('metrics', v, 'as_of', now());
end;
$$;
revoke all on function public.report_metric_catalog() from public, anon, authenticated;
grant execute on function public.report_metric_catalog() to authenticated, service_role;

-- Render one report: latest value + the value ~7 days prior for a WoW delta.
create or replace function public.render_saved_report(p_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare r saved_reports; v jsonb;
begin
  select * into r from saved_reports where id = p_id;
  if not found then raise exception 'Report not found'; end if;
  if not (coalesce(auth.role(), '') = 'service_role'
          or r.owner_id = auth.uid() or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  select jsonb_build_object(
    'id', r.id, 'name', r.name, 'schedule', r.schedule,
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'metric_key', k,
        'value', (select value from metric_snapshots where metric_key = k order by captured_on desc limit 1),
        'captured_on', (select captured_on from metric_snapshots where metric_key = k order by captured_on desc limit 1),
        'prior', (select value from metric_snapshots where metric_key = k
                   and captured_on <= current_date - 7 order by captured_on desc limit 1))
        order by k)
      from unnest(r.metric_keys) k), '[]'::jsonb),
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.render_saved_report(bigint) from public, anon, authenticated;
grant execute on function public.render_saved_report(bigint) to authenticated, service_role;

-- Service-role view of what's due to email (weekly, active, has recipients,
-- not sent in the last 6 days) with each report pre-rendered.
create or replace function public.due_scheduled_reports()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'service role only';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'recipients', s.recipients,
      'report', public.render_saved_report(s.id)))
    from saved_reports s
   where s.is_active and s.schedule = 'weekly'
     and array_length(s.recipients, 1) >= 1
     and (s.last_sent_at is null or s.last_sent_at < now() - interval '6 days')), '[]'::jsonb);
end;
$$;
revoke all on function public.due_scheduled_reports() from public, anon, authenticated;
grant execute on function public.due_scheduled_reports() to service_role;

-- Cron stamps last_sent_at after the edge function reports success.
create or replace function public.mark_report_sent(p_id bigint)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'service role only';
  end if;
  update saved_reports set last_sent_at = now() where id = p_id;
end;
$$;
revoke all on function public.mark_report_sent(bigint) from public, anon, authenticated;
grant execute on function public.mark_report_sent(bigint) to service_role;

-- Monday 07:00 — render + email the due weekly reports.
select cron.schedule('truxon-weekly-reports', '0 7 * * 1',
  $job$select app_private.cron_edge_call('report-send', '{}'::jsonb)$job$);

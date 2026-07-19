-- Sentinel delivery layer. The scan/feed/acknowledge already exist; this adds
-- the "push once" tracking so the scheduled runner alerts on a NEW critical
-- exactly once, plus a compact open-items summary for the daily brief.

alter table public.trux_insights
  add column if not exists notified_at timestamptz;

-- Return open, not-yet-notified CRITICAL insights and stamp them notified in the
-- same statement, so the runner pushes each critical exactly once (a recurrence
-- that auto-resolved and re-opened clears notified_at via the scan's upsert).
create or replace function public.sentinel_take_alerts()
returns setof public.trux_insights
language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return query
  update public.trux_insights
     set notified_at = now()
   where status = 'open' and severity = 'critical' and notified_at is null
  returning *;
end; $$;

-- Compact digest of everything currently open — for the daily brief push.
create or replace function public.sentinel_open_summary()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare open_n int; crit_n int; warn_n int; by_cat jsonb; top jsonb;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select count(*), count(*) filter (where severity='critical'), count(*) filter (where severity='warn')
    into open_n, crit_n, warn_n from public.trux_insights where status <> 'resolved';
  select coalesce(jsonb_object_agg(category, c), '{}'::jsonb) into by_cat
    from (select category, count(*) c from public.trux_insights where status <> 'resolved' group by category) x;
  select coalesce(jsonb_agg(jsonb_build_object('severity', severity, 'title', title, 'detail', detail)), '[]'::jsonb) into top
    from (select severity, title, detail from public.trux_insights where status <> 'resolved'
           order by case severity when 'critical' then 0 when 'warn' then 1 else 2 end, last_seen desc limit 8) t;
  return jsonb_build_object('open', open_n, 'critical', crit_n, 'warn', warn_n, 'by_category', by_cat, 'top', top);
end; $$;

-- When the scan re-opens a resolved insight, clear its notified stamp so a
-- recurrence alerts again. (The scan's own upsert sets status back to 'open';
-- this trigger keeps notified_at consistent with that.)
create or replace function public.trux_insights_clear_notified()
returns trigger language plpgsql as $$
begin
  if new.status = 'open' and old.status = 'resolved' then
    new.notified_at := null;
  end if;
  return new;
end; $$;
drop trigger if exists trux_insights_reopen on public.trux_insights;
create trigger trux_insights_reopen before update on public.trux_insights
  for each row execute function public.trux_insights_clear_notified();

revoke execute on function public.sentinel_take_alerts() from public, anon;
revoke execute on function public.sentinel_open_summary() from public, anon;
grant execute on function public.sentinel_take_alerts() to authenticated, service_role;
grant execute on function public.sentinel_open_summary() to authenticated, service_role;

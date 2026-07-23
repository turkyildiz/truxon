-- R9 #87: sentinel snooze. Ack says "seen"; snooze says "stop telling me for
-- N days" — the finding stays open and truthful in the feed, but the daily
-- brief, weekly digest, and critical push all skip it until the date passes.
alter table public.trux_insights add column if not exists snoozed_until timestamptz;

create or replace function public.snooze_insight(p_id bigint, p_days int default 7)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  update trux_insights
     set snoozed_until = now() + make_interval(days => least(greatest(p_days, 1), 90))
   where id = p_id and status <> 'resolved';
  if not found then
    raise exception 'Insight not found or already resolved' using errcode = 'P0002';
  end if;
end;
$$;
revoke all on function public.snooze_insight(bigint, int) from public, anon;
grant execute on function public.snooze_insight(bigint, int) to authenticated;

-- Reproduced WHOLE from 20260719400001 with the snooze exclusion.
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
     and (snoozed_until is null or snoozed_until < now())
  returning *;
end; $$;

create or replace function public.sentinel_open_summary()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare open_n int; crit_n int; warn_n int; snoozed_n int; by_cat jsonb; top jsonb;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select count(*), count(*) filter (where severity='critical'), count(*) filter (where severity='warn')
    into open_n, crit_n, warn_n from public.trux_insights
   where status <> 'resolved' and (snoozed_until is null or snoozed_until < now());
  select count(*) into snoozed_n from public.trux_insights
   where status <> 'resolved' and snoozed_until >= now();
  select coalesce(jsonb_object_agg(category, c), '{}'::jsonb) into by_cat
    from (select category, count(*) c from public.trux_insights
           where status <> 'resolved' and (snoozed_until is null or snoozed_until < now())
           group by category) x;
  select coalesce(jsonb_agg(jsonb_build_object('severity', severity, 'title', title, 'detail', detail)), '[]'::jsonb) into top
    from (select severity, title, detail from public.trux_insights
           where status <> 'resolved' and (snoozed_until is null or snoozed_until < now())
           order by case severity when 'critical' then 0 when 'warn' then 1 else 2 end, last_seen desc limit 8) t;
  return jsonb_build_object('open', open_n, 'critical', crit_n, 'warn', warn_n,
    'snoozed', snoozed_n, 'by_category', by_cat, 'top', top);
end; $$;

revoke execute on function public.sentinel_take_alerts() from public, anon;
revoke execute on function public.sentinel_open_summary() from public, anon;
grant execute on function public.sentinel_take_alerts() to authenticated, service_role;
grant execute on function public.sentinel_open_summary() to authenticated, service_role;

-- Weekly digest honors snooze too. Reproduced WHOLE from 20260722057001.
create or replace function public.sentinel_weekly_digest()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_groups jsonb;
  v_text text;
  v_open int;
  v_crit int;
  v_new7 int;
  v_res7 int;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() = 'admin') then
    raise exception 'Not enough permissions';
  end if;
  select count(*), count(*) filter (where severity = 'critical')
    into v_open, v_crit from trux_insights
   where status <> 'resolved' and (snoozed_until is null or snoozed_until < now());
  select count(*) filter (where first_seen > now() - interval '7 days'),
         count(*) filter (where resolved_at > now() - interval '7 days')
    into v_new7, v_res7 from trux_insights;

  select jsonb_agg(g order by g.critical desc, g.n desc),
         string_agg(format('%s %s: %s open%s — e.g. %s',
             case when g.critical > 0 then '‼️' else '▫️' end,
             g.category, g.n,
             case when g.critical > 0 then format(' (%s critical)', g.critical) else '' end,
             g.sample),
           E'\n' order by g.critical desc, g.n desc)
    into v_groups, v_text
    from (select category, count(*) n,
                 count(*) filter (where severity = 'critical') as critical,
                 (array_agg(title order by case severity when 'critical' then 0 when 'warn' then 1 else 2 end, last_seen desc))[1] as sample
            from trux_insights
           where status <> 'resolved' and (snoozed_until is null or snoozed_until < now())
           group by category) g;

  return jsonb_build_object(
    'open', v_open, 'critical', v_crit,
    'new_7d', v_new7, 'resolved_7d', v_res7,
    'groups', coalesce(v_groups, '[]'::jsonb),
    'text', coalesce(v_text, 'Nothing open — clean board.'),
    'as_of', now());
end;
$$;
revoke all on function public.sentinel_weekly_digest() from public, anon;
grant execute on function public.sentinel_weekly_digest() to authenticated, service_role;

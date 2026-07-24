-- R9 #176: Forest daily-brief tune-up. The brief's `top` list drove Forest's
-- morning greeting, but it ordered purely by severity then recency — so one
-- noisy category (say six detention warnings) could crowd every other signal
-- out of the top 8, burying a lone fuel-theft warning under dock chatter.
-- This reorders for DIVERSITY: every critical always shows; for warn/info each
-- category contributes at most 2, and the list round-robins across categories
-- (each category's freshest item before any category's second) so the brief is
-- a spread of what's wrong, not a pile of the same thing. Reproduced whole
-- from 20260722058001 (snooze-aware); only the `top` query changed.
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

  with live as (
    select severity, title, detail, category, last_seen,
           case severity when 'critical' then 0 when 'warn' then 1 else 2 end as sev_rank,
           row_number() over (partition by category order by
             case severity when 'critical' then 0 when 'warn' then 1 else 2 end, last_seen desc) as rn_in_cat
      from public.trux_insights
     where status <> 'resolved' and (snoozed_until is null or snoozed_until < now())
  )
  select coalesce(jsonb_agg(jsonb_build_object('severity', severity, 'title', title, 'detail', detail)
           order by sev_rank, rn_in_cat, last_seen desc), '[]'::jsonb) into top
    from (
      select * from live
       where severity = 'critical'   -- every critical is existential; never capped
          or rn_in_cat <= 2          -- warn/info: at most two per category
       order by sev_rank, rn_in_cat, last_seen desc
       limit 8
    ) t;

  return jsonb_build_object('open', open_n, 'critical', crit_n, 'warn', warn_n,
    'snoozed', snoozed_n, 'by_category', by_cat, 'top', top);
end; $$;
revoke execute on function public.sentinel_open_summary() from public, anon;
grant execute on function public.sentinel_open_summary() to authenticated, service_role;

-- R9 #86: weekly sentinel digest — one Monday message, grouped by category
-- and deduped, instead of the owner reconstructing the week from single
-- alerts. The daily brief stays the top-5; this is the map.
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
    into v_open, v_crit from trux_insights where status <> 'resolved';
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
            from trux_insights where status <> 'resolved'
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

-- Monday 12:20 UTC, after the weekly observation (12:00)
do $$ begin perform cron.unschedule('truxon-sentinel-weekly'); exception when others then null; end $$;
select cron.schedule('truxon-sentinel-weekly', '20 12 * * 1',
  $job$select app_private.cron_edge_call('trux-sentinel', '{"mode":"weekly"}'::jsonb)$job$);

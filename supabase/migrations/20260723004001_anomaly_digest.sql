-- R9 #173: "what changed this week" — an auto-narrative over the nightly
-- metric snapshots: big WoW movers as plain sentences with direction and the
-- 13-week slope for context. Snapshot history is young (2026-07-20) so the
-- narrative states its own readiness instead of showing an empty box.
create or replace function public.anomaly_digest(p_threshold_pct numeric default 15)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_lines text;
  v_movers jsonb;
  v_days int;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  select count(distinct captured_on) into v_days from metric_snapshots;

  select string_agg(format('%s %s %s %s%% week-over-week (now %s%s)',
             case when t.wow_pct > 0 then '📈' else '📉' end,
             replace(t.metric_key, '_', ' '),
             case when t.wow_pct > 0 then 'up' else 'down' end,
             abs(round(t.wow_pct)), round(t.latest, 1),
             case when t.slope_13w is not null
               then format(', 13-week slope %s', round(t.slope_13w, 2)) else '' end),
           E'\n' order by abs(t.wow_pct) desc),
         jsonb_agg(jsonb_build_object(
             'metric', t.metric_key, 'latest', round(t.latest, 1),
             'wow_pct', round(t.wow_pct, 1), 'slope_13w', round(t.slope_13w, 2))
           order by abs(t.wow_pct) desc)
    into v_lines, v_movers
    from public.metric_trends(null) t
   where t.wow_pct is not null and abs(t.wow_pct) >= p_threshold_pct and t.points >= 3;

  return jsonb_build_object(
    'snapshot_days', v_days,
    'ready', v_lines is not null,
    'text', coalesce(v_lines,
      case when v_days < 14
        then format('Snapshot history is %s days old — week-over-week narratives begin once two full weeks are banked (nightly since 2026-07-20).', v_days)
        else 'No metric moved more than ' || p_threshold_pct || '%% this week — steady as she goes.' end),
    'movers', coalesce(v_movers, '[]'::jsonb),
    'as_of', now());
end;
$$;
revoke all on function public.anomaly_digest(numeric) from public, anon;
grant execute on function public.anomaly_digest(numeric) to authenticated, service_role;

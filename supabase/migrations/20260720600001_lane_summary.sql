-- R12 #3 — Lane intelligence: every state→state lane ranked by economics.
-- Complements lane_rate_history (single-lane booking benchmark, 20260720340001)
-- with the fleet-wide view: volume, $/mi, margin at the GL all-in cost per
-- mile, deadhead-in share, and last-run recency. Flags lanes priced under
-- break-even. Flips the lane-level playbook metrics that now compute.
create or replace function public.lane_summary(p_days int default 180)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_gl_rpm numeric;
  v_lanes jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  v_gl_rpm := coalesce((public.fleet_cost_basis()->>'gl_all_in_rpm')::numeric,
                       (public.fleet_cost_basis()->>'breakeven_rpm')::numeric, 0);

  select jsonb_agg(t order by t.revenue desc) into v_lanes from (
    select upper(l.pickup_state) || '→' || upper(l.delivery_state) as lane,
           count(*) as loads,
           round(sum(l.rate), 0) as revenue,
           round(sum(l.miles + coalesce(l.empty_miles, 0)), 0) as total_miles,
           round(sum(l.rate) / nullif(sum(l.miles), 0), 2) as rpm,
           round(sum(l.rate) - sum(l.miles + coalesce(l.empty_miles, 0)) * v_gl_rpm, 0) as est_margin,
           round((sum(l.rate) - sum(l.miles + coalesce(l.empty_miles, 0)) * v_gl_rpm)
                 / nullif(sum(l.rate), 0) * 100, 1) as margin_pct,
           round(sum(coalesce(l.empty_miles, 0)) / nullif(sum(l.miles + coalesce(l.empty_miles, 0)), 0) * 100, 1) as deadhead_pct,
           (sum(l.rate) / nullif(sum(l.miles), 0)) < v_gl_rpm as below_breakeven,
           max(l.delivery_time)::date as last_run
      from public.loads l
     where l.status in ('completed', 'billed')
       and l.pickup_state is not null and l.delivery_state is not null
       and l.miles > 0 and l.rate > 0
       and l.delivery_time > now() - (interval '1 day' * greatest(p_days, 1))
     group by 1) t;

  return jsonb_build_object(
    'window_days', p_days,
    'all_in_rpm_basis', v_gl_rpm,
    'lanes', coalesce(v_lanes, '[]'::jsonb));
end;
$$;
revoke all on function public.lane_summary(int) from public, anon;
grant execute on function public.lane_summary(int) to authenticated, service_role;

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'lane_summary(days) — share of lanes with positive est_margin at GL all-in RPM'
where number = 98 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'lane_summary(days) — loads per lane over the window'
where number = 438 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'lane_summary(days) — lane P&L is one call (<1 min); the metric this measures is now structurally satisfied'
where number = 918 and status <> 'live';

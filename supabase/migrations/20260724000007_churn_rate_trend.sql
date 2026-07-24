-- R9 #68/#69: two Northstar early-warning reports over the booking history.
-- #68 customer_churn_watch: the churn SENTINEL already alarms when a broker
--   goes silent past its cadence. This catches the step BEFORE silence — a
--   customer STILL booking but whose recent volume dropped materially vs its
--   own baseline. You can win them back while they're still talking to you.
-- #69 lane_rate_trend: is our pricing power drifting? Per lane, recent $/mi
--   vs the older book — lanes sliding down are where we're leaving money or
--   the market softened; both are worth knowing before the next quote.
create or replace function public.customer_churn_watch(p_min_baseline int default 4, p_drop_pct numeric default 40)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with base as (
    select c.id, c.company_name,
           count(*) filter (where l.created_at > now() - interval '60 days') as recent_60,
           count(*) filter (where l.created_at <= now() - interval '60 days'
                             and l.created_at > now() - interval '180 days') as prior_120,
           sum(l.rate) filter (where l.created_at > now() - interval '180 days') as rev_180
      from customers c join loads l on l.customer_id = c.id
     where l.status <> 'cancelled' and l.created_at > now() - interval '180 days'
       and c.is_active and not c.do_not_use
     group by c.id, c.company_name
  ), rated as (
    -- normalize both windows to loads-per-30-days, then the drop
    select *, round(recent_60 / 2.0, 1) as recent_rate,
           round(prior_120 / 4.0, 1) as baseline_rate,
           case when prior_120 > 0
                then round((prior_120 / 4.0 - recent_60 / 2.0) / (prior_120 / 4.0) * 100, 0)
           end as drop_pct
      from base
  )
  select jsonb_build_object(
    'min_baseline', p_min_baseline, 'drop_threshold_pct', p_drop_pct,
    'watch', coalesce((select jsonb_agg(jsonb_build_object(
        'customer', r.company_name, 'baseline_per_30d', r.baseline_rate,
        'recent_per_30d', r.recent_rate, 'drop_pct', r.drop_pct,
        'trailing_revenue', round(r.rev_180, 2)) order by r.drop_pct desc, r.rev_180 desc)
      from rated r
     where r.prior_120 >= p_min_baseline   -- had a real baseline
       and r.recent_60 >= 1                -- still booking (not gone — that's the sentinel)
       and r.drop_pct >= p_drop_pct), '[]'::jsonb),
    'note', 'these customers are still booking but at a materially lower rate than their own baseline — an early warning distinct from the gone-silent sentinel; a call now is cheaper than a win-back',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.customer_churn_watch(int, numeric) from public, anon, authenticated;
grant execute on function public.customer_churn_watch(int, numeric) to authenticated, service_role;

create or replace function public.lane_rate_trend(p_min_loads int default 4, p_move_pct numeric default 8)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with lanes as (
    select upper(pickup_state) as o, upper(delivery_state) as d,
           avg(rate / nullif(miles, 0)) filter (where created_at > now() - interval '90 days'
                and miles > 0) as recent_rpm,
           count(*) filter (where created_at > now() - interval '90 days') as recent_n,
           avg(rate / nullif(miles, 0)) filter (where created_at <= now() - interval '90 days'
                and created_at > now() - interval '365 days' and miles > 0) as prior_rpm,
           count(*) filter (where created_at <= now() - interval '90 days'
                and created_at > now() - interval '365 days') as prior_n
      from loads
     where status in ('completed','billed') and pickup_state <> '' and delivery_state <> ''
       and created_at > now() - interval '365 days'
     group by upper(pickup_state), upper(delivery_state)
  ), moved as (
    select *, round((recent_rpm - prior_rpm) / nullif(prior_rpm, 0) * 100, 1) as move_pct
      from lanes where recent_n >= p_min_loads and prior_n >= p_min_loads
        and recent_rpm is not null and prior_rpm is not null
  )
  select jsonb_build_object(
    'min_loads', p_min_loads, 'move_threshold_pct', p_move_pct,
    'falling', coalesce((select jsonb_agg(jsonb_build_object(
        'lane', o||'→'||d, 'recent_rpm', round(recent_rpm, 2), 'prior_rpm', round(prior_rpm, 2),
        'move_pct', move_pct, 'recent_loads', recent_n) order by move_pct asc)
      from moved where move_pct <= -p_move_pct), '[]'::jsonb),
    'rising', coalesce((select jsonb_agg(jsonb_build_object(
        'lane', o||'→'||d, 'recent_rpm', round(recent_rpm, 2), 'prior_rpm', round(prior_rpm, 2),
        'move_pct', move_pct, 'recent_loads', recent_n) order by move_pct desc)
      from moved where move_pct >= p_move_pct), '[]'::jsonb),
    'note', 'recent 90d $/mi vs the prior 9 months on the same lane; falling lanes are lost pricing power or a softening market — worth a look before the next quote',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.lane_rate_trend(int, numeric) from public, anon, authenticated;
grant execute on function public.lane_rate_trend(int, numeric) to authenticated, service_role;

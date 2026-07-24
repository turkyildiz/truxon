-- R9 #65/#73.
-- #65 forecast MAPE tracking: we forecast revenue per upcoming week but never
--   kept a record of what we predicted, so we could never grade ourselves.
--   forecast_snapshots banks each week's prediction; once a target week has
--   passed and the actuals are in, forecast_mape_report() scores the error.
--   The scoreboard is empty until snapshots mature — that's honest, it fills
--   as the weeks turn. A Monday cron takes the snapshot.
-- #73 truck-retirement what-if: pull one unit, redistribute its recent loads
--   across the remaining fleet, and see whether the survivors have the miles
--   headroom to absorb them — plus the fixed cost saved and the revenue at
--   risk if they can't. The mirror image of the add-a-truck model (#74).
create table if not exists public.forecast_snapshots (
  id bigserial primary key,
  metric text not null default 'revenue_week',
  made_on date not null default current_date,
  target_week date not null,                     -- the trux_week_start being predicted
  predicted numeric not null,
  basis text not null default '',
  created_at timestamptz not null default now(),
  unique (metric, made_on, target_week)
);
alter table public.forecast_snapshots enable row level security;
revoke all on table public.forecast_snapshots from anon, authenticated;
grant select on public.forecast_snapshots to authenticated;
drop policy if exists fs_read on public.forecast_snapshots;
create policy fs_read on public.forecast_snapshots
  for select to authenticated using (public.my_role() in ('admin','accountant','dispatcher'));
insert into app_private.security_baseline (kind, item)
values ('grant', 'authenticated forecast_snapshots SELECT') on conflict do nothing;

-- Bank this week's forward revenue forecast (service role / cron).
create or replace function public.capture_revenue_forecast()
returns int
language plpgsql security definer set search_path = public
as $$
declare n int := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'service role only';
  end if;
  insert into forecast_snapshots (metric, made_on, target_week, predicted, basis)
  select 'revenue_week', current_date, f.week_start, f.forecast_revenue, f.basis
    from public.revenue_forecast(6) f
  on conflict (metric, made_on, target_week) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.capture_revenue_forecast() from public, anon, authenticated;
grant execute on function public.capture_revenue_forecast() to service_role;

-- Score matured forecasts: for each target week now in the past, compare the
-- earliest prediction made for it to the realized revenue. MAPE + bias.
create or replace function public.forecast_mape_report(p_weeks int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with matured as (
    -- one prediction per target week: the earliest lead-time snapshot
    select distinct on (target_week) target_week, predicted, made_on
      from forecast_snapshots
     where metric = 'revenue_week'
       and target_week < public.trux_week_start(current_date)
       and target_week >= public.trux_week_start(current_date) - (p_weeks * 7)
     order by target_week, made_on
  ), actuals as (
    select public.trux_week_start(l.delivery_time::date) as ws, sum(l.rate) as actual
      from loads l where l.status in ('completed','billed')
       and l.delivery_time is not null
     group by 1
  ), scored as (
    select m.target_week, m.predicted, a.actual, m.made_on,
           abs(m.predicted - coalesce(a.actual, 0)) as abs_err,
           case when coalesce(a.actual, 0) > 0
                then abs(m.predicted - a.actual) / a.actual * 100 end as ape,
           m.predicted - coalesce(a.actual, 0) as bias
      from matured m left join actuals a on a.ws = m.target_week
  )
  select jsonb_build_object(
    'weeks_scored', (select count(*) from scored where ape is not null),
    'mape_pct', (select round(avg(ape), 1) from scored where ape is not null),
    'mean_bias', (select round(avg(bias), 0) from scored where actual is not null),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object(
        'target_week', s.target_week, 'predicted', round(s.predicted, 0),
        'actual', round(s.actual, 0), 'error_pct', round(s.ape, 1)) order by s.target_week desc)
      from scored s where s.ape is not null), '[]'::jsonb),
    'note', 'earliest prediction per week vs realized revenue; positive mean bias = we forecast high. Empty until snapshots mature (Monday cron banks them going forward).',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.forecast_mape_report(int) from public, anon, authenticated;
grant execute on function public.forecast_mape_report(int) to authenticated, service_role;

select cron.schedule('truxon-forecast-snapshot', '30 6 * * 1',
  $job$select public.capture_revenue_forecast()$job$);

-- #73 truck-retirement what-if.
create or replace function public.truck_retirement_scenario(p_truck_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
  t trucks;
  v_rem_trucks int;
  v_wk_loads numeric; v_wk_miles numeric; v_wk_rev numeric;   -- the unit's weekly averages
  v_rem_avg_miles numeric;                                    -- survivors' avg weekly miles
  v_cap_headroom numeric;                                     -- assume a truck can run ~2500 loaded mi/wk
  cb jsonb := public.fleet_cost_basis();
  v_margin numeric;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select * into t from trucks where id = p_truck_id;
  if not found then raise exception 'Truck not found'; end if;

  select round(count(*) / 12.0, 1), round(coalesce(sum(miles), 0) / 12.0, 0), round(coalesce(sum(rate), 0) / 12.0, 0)
    into v_wk_loads, v_wk_miles, v_wk_rev
    from loads where truck_id = p_truck_id and status in ('completed','billed')
      and delivery_time > now() - interval '12 weeks';

  select count(*) into v_rem_trucks from trucks where status <> 'retired' and id <> p_truck_id;
  select round(coalesce(sum(miles), 0) / 12.0 / nullif(v_rem_trucks, 0), 0)
    into v_rem_avg_miles
    from loads l join trucks tk on tk.id = l.truck_id
   where tk.status <> 'retired' and tk.id <> p_truck_id
     and l.status in ('completed','billed') and l.delivery_time > now() - interval '12 weeks';

  -- headroom per surviving truck toward a ~2500 loaded-mi/wk practical ceiling
  v_cap_headroom := greatest(2500 - coalesce(v_rem_avg_miles, 0), 0) * v_rem_trucks;
  v_margin := coalesce((cb->>'avg_rpm')::numeric, 0)
              - greatest(coalesce((cb->>'breakeven_rpm')::numeric, 0) - coalesce((cb->>'fixed_per_mile')::numeric, 0), 0);

  select jsonb_build_object(
    'unit', t.unit_number, 'status', t.status,
    'retiring_truck', jsonb_build_object(
      'weekly_loads', v_wk_loads, 'weekly_miles', v_wk_miles, 'weekly_revenue', v_wk_rev,
      'monthly_fixed_saved', coalesce(t.monthly_cost, 0)),
    'redistribution', jsonb_build_object(
      'remaining_trucks', v_rem_trucks,
      'survivor_avg_weekly_miles', v_rem_avg_miles,
      'fleet_headroom_weekly_miles', round(v_cap_headroom, 0),
      'absorbable', v_wk_miles is not null and v_cap_headroom >= v_wk_miles,
      'revenue_at_risk', case when v_wk_miles is not null and v_cap_headroom < v_wk_miles
        then round((v_wk_miles - v_cap_headroom) * coalesce((cb->>'avg_rpm')::numeric, 0), 0) else 0 end),
    'verdict', case
      when v_rem_trucks = 0 then 'this is the last truck — retirement ends operations'
      when v_wk_miles is null then 'the unit ran no loads in the last 12 weeks — retire freely'
      when v_cap_headroom >= v_wk_miles then 'the remaining fleet can absorb its miles; net of the '||coalesce(t.monthly_cost,0)||'/mo fixed cost saved, this looks clean'
      else 'the fleet is near capacity — some of its freight (or revenue) would go uncovered' end,
    'note', 'weekly figures are 12-week averages; headroom assumes a practical ~2500 loaded-mi/wk per truck ceiling. Margin uses the fleet cost basis.',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.truck_retirement_scenario(bigint) from public, anon, authenticated;
grant execute on function public.truck_retirement_scenario(bigint) to authenticated, service_role;

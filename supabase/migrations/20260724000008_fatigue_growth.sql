-- R9 #71/#74: two Northstar analytics.
-- #71 driver_fatigue_watch: long-day streaks. We don't bank per-driver daily
--   HOS, so the honest proxy is DAYS-ON: the calendar days each driver had a
--   load in motion (pickup..delivery span). A long unbroken run of work-days
--   with no reset is the fatigue signal; gaps-and-islands finds the current
--   streak and flags drivers at or past the threshold.
-- #74 truck_breakeven_analysis: the 13th-truck decision from real economics —
--   how many loaded miles a week a new truck must turn to cover its own added
--   fixed cost at the fleet's current contribution margin, next to what the
--   average truck actually runs, so "can we fill it?" is a number not a vibe.
create or replace function public.driver_fatigue_watch(p_min_streak int default 6, p_days int default 30)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with work_days as (
    -- one row per (driver, calendar day they had a load in motion)
    select distinct l.driver_id, gs::date as d
      from loads l,
           generate_series(l.pickup_time::date,
                           coalesce(l.delivery_time, l.pickup_time)::date, interval '1 day') gs
     where l.driver_id is not null and l.pickup_time is not null
       and l.status in ('in_transit','delivered','completed','billed')
       and l.pickup_time > now() - make_interval(days => p_days + 14)
  ), islands as (
    -- gaps-and-islands: consecutive days share (d - row_number)
    select driver_id, d,
           d - (row_number() over (partition by driver_id order by d))::int as grp
      from work_days
  ), streaks as (
    select driver_id, grp, count(*) as streak_len, min(d) as start_d, max(d) as end_d
      from islands group by driver_id, grp
  ), current as (
    -- the driver's most recent streak (ending closest to now)
    select distinct on (driver_id) driver_id, streak_len, start_d, end_d
      from streaks order by driver_id, end_d desc
  )
  select jsonb_build_object(
    'min_streak', p_min_streak, 'days', p_days,
    'flagged', coalesce((select jsonb_agg(jsonb_build_object(
        'driver', d.full_name, 'consecutive_days', c.streak_len,
        'streak_start', c.start_d, 'last_active', c.end_d) order by c.streak_len desc)
      from current c join drivers d on d.id = c.driver_id
     where c.streak_len >= p_min_streak
       and c.end_d >= (current_date - 3)), '[]'::jsonb),  -- still ongoing
    'note', 'streak = consecutive calendar days with a load in motion (pickup..delivery span) — a days-on proxy since per-driver daily HOS is not banked; only currently-running streaks are flagged',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.driver_fatigue_watch(int, int) from public, anon, authenticated;
grant execute on function public.driver_fatigue_watch(int, int) to authenticated, service_role;

create or replace function public.truck_breakeven_analysis()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
  cb jsonb := public.fleet_cost_basis();
  v_avg_rpm numeric := coalesce((cb->>'avg_rpm')::numeric, 0);
  v_breakeven_rpm numeric := coalesce((cb->>'breakeven_rpm')::numeric, 0);
  v_fixed_per_mile numeric := coalesce((cb->>'fixed_per_mile')::numeric, 0);
  v_variable_per_mile numeric;      -- breakeven minus the fixed slice
  v_margin_per_mile numeric;        -- contribution before fixed
  v_active int;
  v_weekly_fixed_per_truck numeric;
  v_avg_weekly_miles numeric;
  v_breakeven_miles numeric;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  v_variable_per_mile := greatest(v_breakeven_rpm - v_fixed_per_mile, 0);
  v_margin_per_mile := round(v_avg_rpm - v_variable_per_mile, 3);

  select count(*), coalesce(sum(monthly_cost), 0) / 4.33 / nullif(count(*), 0)
    into v_active, v_weekly_fixed_per_truck
    from trucks where status <> 'retired';

  -- avg loaded miles per truck per week over the last 12 weeks
  select round(coalesce(sum(miles), 0) / 12.0 / nullif(v_active, 0), 0)
    into v_avg_weekly_miles
    from loads where status in ('completed','billed')
     and delivery_time > now() - interval '12 weeks';

  v_breakeven_miles := case when v_margin_per_mile > 0
    then round(v_weekly_fixed_per_truck / v_margin_per_mile, 0) end;

  select jsonb_build_object(
    'current_trucks', v_active,
    'economics', jsonb_build_object(
      'avg_rpm', v_avg_rpm, 'variable_per_mile', round(v_variable_per_mile, 3),
      'contribution_margin_per_mile', v_margin_per_mile,
      'weekly_fixed_cost_per_truck', round(v_weekly_fixed_per_truck, 2)),
    'new_truck', jsonb_build_object(
      'breakeven_loaded_miles_per_week', v_breakeven_miles,
      'fleet_avg_loaded_miles_per_week', v_avg_weekly_miles,
      'headroom_pct', case when v_breakeven_miles > 0 and v_avg_weekly_miles is not null
        then round((v_avg_weekly_miles - v_breakeven_miles) / v_breakeven_miles * 100, 0) end,
      'verdict', case
        when v_margin_per_mile <= 0 then 'margin per mile is not positive — a new truck loses money at current rates'
        when v_breakeven_miles is null or v_avg_weekly_miles is null then 'insufficient data'
        when v_avg_weekly_miles >= v_breakeven_miles * 1.15 then 'clear: the average truck already runs well past this truck''s breakeven'
        when v_avg_weekly_miles >= v_breakeven_miles then 'tight: average utilization just covers it — only add with committed freight'
        else 'risky: the average truck runs below the breakeven miles a new truck needs' end),
    'note', 'contribution margin = avg $/mi − variable $/mi (fuel+pay+tolls); a new truck must turn its weekly fixed cost ÷ that margin in loaded miles. Compares to the current per-truck average; assumes the new truck earns the fleet-average rate.',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.truck_breakeven_analysis() from public, anon, authenticated;
grant execute on function public.truck_breakeven_analysis() to authenticated, service_role;

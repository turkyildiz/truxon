-- R9 #26: DVIR compliance % on the weekly driver scorecard. Denominator is
-- ELD truth — days this week the driver's truck(s) actually moved (>5 mi, so
-- yard creep doesn't count as a driving day); numerator is days with a
-- pre-trip DVIR from that driver. Null when ELD tracked no driving days —
-- no fake 100%s. Full driver_scorecard redefinition (latest = 20260720610001).
create or replace function public.driver_scorecard(p_week_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  ws date := public.trux_week_start(current_date) - (7 * greatest(p_week_offset, 0));
  we date;
  v_days_back int;
  v_rows jsonb;
  v_solo numeric;
  v_drivers int;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  we := ws + 7;
  v_days_back := greatest((current_date - ws)::int + 1, 1);

  select count(*) into v_drivers from drivers where status = 'active';
  select round(sum(l.rate) / nullif(v_drivers, 0), 2) into v_solo
    from loads l
   where l.status in ('completed', 'billed')
     and l.delivery_time >= ws and l.delivery_time < we
     and coalesce(l.equipment_type, '') not ilike '%team%';

  select jsonb_agg(t order by t.revenue desc nulls last) into v_rows from (
    with wk_loads as (
      select l.* from loads l
       where l.status in ('completed', 'billed')
         and l.delivery_time >= ws and l.delivery_time < we and l.driver_id is not null
    ),
    det as (
      select d.load_id, sum(d.detention_min) det_min
        from public.detention_events(v_days_back) d
       group by d.load_id
    ),
    arr as (
      select w.id, w.driver_id, w.delivery_time,
             (select min(h.ts) from eld_location_history h
               where h.truck_id = w.truck_id
                 and h.ts between w.delivery_time - interval '18 hours' and w.delivery_time + interval '18 hours'
                 and public.trux_miles(w.delivery_lat, w.delivery_lon, h.lat, h.lng) <= 0.75) eld_arr
        from wk_loads w
       where w.truck_id is not null and w.delivery_lat is not null
    )
    select d.full_name as driver,
           count(w.id) as loads,
           round(sum(w.miles + coalesce(w.empty_miles, 0)), 0) as total_miles,
           round(sum(w.rate), 2) as revenue,
           round(sum(w.rate) / nullif(sum(w.miles), 0), 2) as rpm,
           round(sum(w.miles * d.pay_per_mile
                 + case when d.empty_miles_paid then coalesce(w.empty_miles, 0) * d.pay_per_empty_mile else 0 end), 2) as est_pay,
           (select case when count(*) > 0 then round(
                     count(*) filter (where a.eld_arr <= a.delivery_time + interval '2 hours')::numeric
                     / count(*) * 100, 0) end
              from arr a where a.driver_id = d.id and a.eld_arr is not null) as on_time_pct,
           round(coalesce(sum(dt.det_min), 0) / 60.0, 1) as detention_hours,
           (select count(*) from safety_events se
             where se.driver_id = d.id and se.event_type = 'violation'
               and se.event_date >= ws and se.event_date < we) as violations,
           (select round(
                count(*) filter (where exists (
                  select 1 from dvir dv
                   where dv.driver_id = d.id and dv.inspection_type = 'pre_trip'
                     and dv.created_at::date = v.day))::numeric
                / nullif(count(*), 0) * 100, 0)
              from (select em.day
                      from eld_daily_miles em
                     where em.day >= ws and em.day < we
                       and em.truck_id in (select w2.truck_id from wk_loads w2
                                            where w2.driver_id = d.id and w2.truck_id is not null)
                     group by em.day
                    having sum(em.miles) > 5) v) as dvir_pct
      from wk_loads w
      join drivers d on d.id = w.driver_id
      left join det dt on dt.load_id = w.id
     group by d.id, d.full_name) t;

  return jsonb_build_object(
    'week_start', ws, 'week_end', we - 1,
    'solo_revenue_per_driver_per_week', v_solo,
    'drivers', coalesce(v_rows, '[]'::jsonb));
end;
$$;
revoke all on function public.driver_scorecard(int) from public, anon;
grant execute on function public.driver_scorecard(int) to authenticated, service_role;

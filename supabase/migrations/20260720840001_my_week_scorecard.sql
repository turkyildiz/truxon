-- R3 #11 — driver self-scorecard: the companion app shows each driver THEIR
-- week (loads, miles, est pay, on-time, detention hours). Same math as the
-- office driver_scorecard, scoped to the caller's linked driver row; company
-- revenue deliberately excluded from the driver-facing card.
create function public.my_week_scorecard(p_week_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  ws date := public.trux_week_start(current_date) - (7 * greatest(p_week_offset, 0));
  we date;
  v_days_back int;
  v_driver_id bigint;
  v_row jsonb;
begin
  select d.id into v_driver_id from drivers d where d.user_id = auth.uid();
  if v_driver_id is null then
    return null;  -- office user or unlinked login: no card
  end if;
  we := ws + 7;
  v_days_back := greatest((current_date - ws)::int + 1, 1);

  select to_jsonb(t) into v_row from (
    with wk_loads as (
      select l.* from loads l
       where l.status in ('completed', 'billed')
         and l.delivery_time >= ws and l.delivery_time < we
         and l.driver_id = v_driver_id
    ),
    det as (
      select d.load_id, sum(d.detention_min) det_min
        from public.detention_events(v_days_back) d
       group by d.load_id
    ),
    arr as (
      select w.id, w.delivery_time,
             (select min(h.ts) from eld_location_history h
               where h.truck_id = w.truck_id
                 and h.ts between w.delivery_time - interval '18 hours' and w.delivery_time + interval '18 hours'
                 and public.trux_miles(w.delivery_lat, w.delivery_lon, h.lat, h.lng) <= 0.75) eld_arr
        from wk_loads w
       where w.truck_id is not null and w.delivery_lat is not null
    )
    select count(w.id) as loads,
           round(coalesce(sum(w.miles + coalesce(w.empty_miles, 0)), 0), 0) as total_miles,
           round(coalesce(sum(w.miles * d.pay_per_mile
                 + case when d.empty_miles_paid then coalesce(w.empty_miles, 0) * d.pay_per_empty_mile else 0 end), 0), 2) as est_pay,
           (select case when count(*) > 0 then round(
                     count(*) filter (where a.eld_arr <= a.delivery_time + interval '2 hours')::numeric
                     / count(*) * 100, 0) end
              from arr a where a.eld_arr is not null) as on_time_pct,
           round(coalesce(sum(dt.det_min), 0) / 60.0, 1) as detention_hours
      from wk_loads w
      join drivers d on d.id = v_driver_id
      left join det dt on dt.load_id = w.id) t;

  return jsonb_build_object('week_start', ws, 'week_end', we - 1) || coalesce(v_row, '{}'::jsonb);
end;
$$;
revoke all on function public.my_week_scorecard(int) from public, anon;
grant execute on function public.my_week_scorecard(int) to authenticated, service_role;

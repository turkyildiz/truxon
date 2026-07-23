-- Live-caught: ifta_attribute_states DELETES the state='' aggregate row after
-- splitting a day into per-state rows. Two consumers written against '' rows
-- were therefore wrong on prod:
--   * eld_gap_days counted every ATTRIBUTED day as a gap (156 "gaps" were
--     really 63) — and the filler kept refetching days that were already
--     banked, whose fresh '' rows attribution then deleted again nightly.
--   * truck_utilization saw 0 moving days fleet-wide.
-- Both now treat "any row for that truck-day" as banked and sum miles across
-- state rows.
create or replace function public.eld_gap_days(p_back int default 14)
returns table (vehicle_id uuid, truck_id bigint, day date)
language sql stable security definer set search_path = public
as $$
  select ev.vehicle_id, ev.truck_id, d.day::date
    from eld_vehicles ev
    cross join generate_series(current_date - least(greatest(p_back, 2), 60),
                               current_date - 2, interval '1 day') d(day)
   where ev.truck_id is not null and coalesce(ev.active, true)
     and auth.role() = 'service_role'
     and not exists (select 1 from eld_daily_miles em
                      where em.truck_id = ev.truck_id and em.day = d.day::date)
   order by 3 desc, 2;
$$;
revoke all on function public.eld_gap_days(int) from public, anon, authenticated;
grant execute on function public.eld_gap_days(int) to service_role;

create or replace function public.truck_utilization(p_days int default 28)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_rows jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select jsonb_agg(t order by t.moving_days desc, t.revenue desc) into v_rows from (
    select tk.unit_number as unit,
           count(*) filter (where em.mi > 5) as moving_days,
           count(*) filter (where em.mi <= 5) as parked_days,
           count(*) as banked_days,
           round(sum(em.mi) filter (where extract(isodow from em.day) in (6,7))
                 / nullif(sum(em.mi), 0) * 100, 0) as weekend_miles_pct,
           coalesce(r.revenue, 0) as revenue,
           case when count(*) filter (where em.mi > 5) > 0
             then round(coalesce(r.revenue, 0) / count(*) filter (where em.mi > 5), 0) end
             as revenue_per_moving_day
      from trucks tk
      join (select truck_id, day, sum(miles) as mi
              from eld_daily_miles
             where day >= current_date - p_days and day < current_date
             group by truck_id, day) em on em.truck_id = tk.id
      left join lateral (
        select round(sum(l.rate), 2) revenue from loads l
         where l.truck_id = tk.id and l.status in ('completed','billed')
           and l.delivery_time >= current_date - p_days) r on true
     where tk.status <> 'retired'
     group by tk.id, tk.unit_number, r.revenue) t;
  return jsonb_build_object(
    'days', p_days,
    'trucks', coalesce(v_rows, '[]'::jsonb),
    'note', 'moving = ELD-banked day >5 mi (summed across state rows); unbanked days excluded, not guessed',
    'as_of', now());
end;
$$;
revoke all on function public.truck_utilization(int) from public, anon;
grant execute on function public.truck_utilization(int) to authenticated, service_role;

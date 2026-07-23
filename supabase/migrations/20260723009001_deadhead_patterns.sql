-- R9 #126: deadhead optimizer report — which regions strand the trucks.
-- Consecutive completed loads per truck: delivering into state X, how far to
-- the next pickup (straight-line between geocoded stops ×1.2 road factor,
-- or the booked empty_miles when the next load carries one). Ranked by the
-- repositioning bill per delivery state.
create or replace function public.deadhead_patterns(p_days int default 120)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  with seq as (
    select l.truck_id, l.delivery_state, l.delivery_lat, l.delivery_lon, l.delivery_time,
           lead(l.pickup_lat) over w as next_plat,
           lead(l.pickup_lon) over w as next_plon,
           lead(l.pickup_state) over w as next_pstate,
           lead(l.empty_miles) over w as next_empty,
           lead(l.pickup_time) over w as next_ptime
      from loads l
     where l.truck_id is not null and l.status in ('completed','billed')
       and l.delivery_time > now() - make_interval(days => p_days)
    window w as (partition by l.truck_id order by l.delivery_time)
  ), hops as (
    select delivery_state, next_pstate,
           coalesce(nullif(next_empty, 0),
                    public.trux_miles(delivery_lat, delivery_lon, next_plat, next_plon) * 1.2) as dh_miles
      from seq
     where next_ptime is not null
       and next_ptime < delivery_time + interval '7 days'
       and (next_empty > 0 or (delivery_lat is not null and next_plat is not null))
  )
  select jsonb_build_object(
    'days', p_days,
    'hops_measured', (select count(*) from hops where dh_miles is not null),
    'avg_deadhead_miles', (select round(avg(dh_miles), 0) from hops where dh_miles is not null),
    'by_delivery_state', coalesce((select jsonb_agg(jsonb_build_object(
        'state', x.delivery_state, 'hops', x.n,
        'avg_deadhead', round(x.avg_dh, 0), 'total_deadhead', round(x.tot, 0))
        order by x.tot desc)
      from (select delivery_state, count(*) n, avg(dh_miles) avg_dh, sum(dh_miles) tot
              from hops where dh_miles is not null and delivery_state is not null
             group by delivery_state having count(*) >= 2) x), '[]'::jsonb),
    'worst_pairs', coalesce((select jsonb_agg(jsonb_build_object(
        'from', y.delivery_state, 'to_pickup', y.next_pstate,
        'hops', y.n, 'avg_deadhead', round(y.avg_dh, 0)) order by y.avg_dh desc)
      from (select delivery_state, next_pstate, count(*) n, avg(dh_miles) avg_dh
              from hops where dh_miles is not null
             group by delivery_state, next_pstate
            having count(*) >= 2 and avg(dh_miles) >= 100
             order by avg(dh_miles) desc limit 8) y), '[]'::jsonb),
    'note', 'straight-line x1.2 when no booked empty miles; hops capped at 7 days between loads',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.deadhead_patterns(int) from public, anon;
grant execute on function public.deadhead_patterns(int) to authenticated, service_role;

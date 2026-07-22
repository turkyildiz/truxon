-- Playbook march, Operations cluster (R7 block 1). on_time_delivery_pct already
-- lives in company_scorecard from the ELD-arrival-vs-appointment pattern; this
-- applies the SAME measurement to the pickup leg and combines them, unlocking
-- on-time pickup, combined on-time service, and the two missed-appointment
-- rates. Only ELD-covered legs are "measured" (same honest limit as delivery).
create or replace function public.ops_service_metrics(p_days int default 90)
returns jsonb
language plpgsql security definer set search_path = public stable
as $$
declare
  p_start timestamptz := now() - (p_days || ' days')::interval;
  v_pu_meas int; v_pu_hit int;
  v_del_meas int; v_del_hit int;
  v_both_meas int; v_both_hit int;
begin
  if auth.uid() is not null and public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  with legs as (
    select l.id,
           l.pickup_time, l.delivery_time,
           (select min(h.ts) from public.eld_location_history h
             where h.truck_id = l.truck_id
               and h.ts between l.pickup_time - interval '18 hours' and l.pickup_time + interval '18 hours'
               and public.trux_miles(l.pickup_lat, l.pickup_lon, h.lat, h.lng) <= 0.75) as pu_arr,
           (select min(h.ts) from public.eld_location_history h
             where h.truck_id = l.truck_id
               and h.ts between l.delivery_time - interval '18 hours' and l.delivery_time + interval '18 hours'
               and public.trux_miles(l.delivery_lat, l.delivery_lon, h.lat, h.lng) <= 0.75) as del_arr
      from public.loads l
     where l.status in ('completed','billed')
       and l.delivery_time >= p_start and l.truck_id is not null
       and l.pickup_lat is not null and l.pickup_time is not null
       and l.delivery_lat is not null and l.delivery_time is not null
  )
  select
    count(*) filter (where pu_arr is not null),
    count(*) filter (where pu_arr is not null and pu_arr <= pickup_time + interval '2 hours'),
    count(*) filter (where del_arr is not null),
    count(*) filter (where del_arr is not null and del_arr <= delivery_time + interval '2 hours'),
    count(*) filter (where pu_arr is not null and del_arr is not null),
    count(*) filter (where pu_arr is not null and del_arr is not null
                       and pu_arr <= pickup_time + interval '2 hours'
                       and del_arr <= delivery_time + interval '2 hours')
    into v_pu_meas, v_pu_hit, v_del_meas, v_del_hit, v_both_meas, v_both_hit
    from legs;

  return jsonb_build_object(
    'on_time_pickup_pct',   case when v_pu_meas   > 0 then round(v_pu_hit::numeric   / v_pu_meas   * 100, 1) end,
    'on_time_delivery_pct', case when v_del_meas  > 0 then round(v_del_hit::numeric  / v_del_meas  * 100, 1) end,
    'on_time_service_pct',  case when v_both_meas > 0 then round(v_both_hit::numeric / v_both_meas * 100, 1) end,
    'missed_pickup_pct',    case when v_pu_meas   > 0 then round((v_pu_meas  - v_pu_hit)::numeric  / v_pu_meas   * 100, 1) end,
    'missed_delivery_pct',  case when v_del_meas  > 0 then round((v_del_meas - v_del_hit)::numeric / v_del_meas  * 100, 1) end,
    'pickup_sample', v_pu_meas, 'delivery_sample', v_del_meas, 'as_of', now()
  );
end;
$$;
revoke all on function public.ops_service_metrics(int) from public, anon;
grant execute on function public.ops_service_metrics(int) to authenticated, service_role;

update public.playbook_metrics set status='live', source='ops_service_metrics().on_time_pickup_pct',  updated_at=now() where number = 212;
update public.playbook_metrics set status='live', source='ops_service_metrics().on_time_service_pct',  updated_at=now() where number = 214;
update public.playbook_metrics set status='live', source='ops_service_metrics().missed_pickup_pct',    updated_at=now() where number = 291;
update public.playbook_metrics set status='live', source='ops_service_metrics().missed_delivery_pct',  updated_at=now() where number = 292;

-- Northstar: a few more computable ops metrics (playbook #206/#208/#285/#286),
-- all derivable from loads in the window. Kept out of the big scorecard to avoid
-- another reproduction; Trux calls this directly. Admin/dispatcher/accountant +
-- service_role.
create or replace function public.fleet_ops_extras(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  win_days numeric := greatest(extract(epoch from (p_end - p_start)) / 86400.0, 1);
  weeks numeric := greatest(win_days / 7.0, 0.1);
  loads_n int; total_mi numeric; empty_mi numeric; drivers_n int;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','dispatcher','accountant') then
    raise exception 'Not enough permissions';
  end if;
  select count(*), coalesce(sum(miles),0) + coalesce(sum(empty_miles),0),
         coalesce(sum(empty_miles),0), count(distinct driver_id) filter (where driver_id is not null)
    into loads_n, total_mi, empty_mi, drivers_n
    from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;

  return jsonb_build_object(
    'deadhead_miles_per_dispatch', case when loads_n > 0 then round(empty_mi / loads_n, 0) end,
    'miles_per_driver_per_week',   case when drivers_n > 0 then round(total_mi / drivers_n / weeks, 0) end,
    'loads_per_day',               round(loads_n / win_days, 1),
    'miles_per_day',               round(total_mi / win_days, 0),
    'working_drivers',             drivers_n);
end;
$$;
revoke all on function public.fleet_ops_extras(timestamptz, timestamptz) from public, anon;
grant execute on function public.fleet_ops_extras(timestamptz, timestamptz) to authenticated;

update public.playbook_metrics as m set status='live', source=v.src, updated_at=now()
from (values
  (206, 'fleet_ops_extras.deadhead_miles_per_dispatch'),
  (208, 'fleet_ops_extras.miles_per_driver_per_week'),
  (285, 'fleet_ops_extras.loads_per_day'),
  (286, 'fleet_ops_extras.miles_per_day')
) as v(number, src)
where m.number = v.number and m.status <> 'live';

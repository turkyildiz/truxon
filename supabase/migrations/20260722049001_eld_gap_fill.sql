-- R9 #57: eld_daily_miles gap-filler. The miles bank skips days (rollup runs
-- before the history sweep; live sync drops points), which poisoned MPG,
-- IFTA, DVIR %, and tonight's no-mileage-day sentinels. DriveHOS keeps
-- history server-side, so missed days are RECOVERABLE: eld-sync's new
-- gapfill mode asks this function what's missing, re-fetches those exact
-- vehicle-days, re-banks them, and stamps a zero-marker row when the API
-- confirms the truck really sat (so "checked and parked" is distinguishable
-- from "never checked").
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
                      where em.truck_id = ev.truck_id and em.day = d.day::date and em.state = '')
   order by 3, 2;
$$;
revoke all on function public.eld_gap_days(int) from public, anon, authenticated;
grant execute on function public.eld_gap_days(int) to service_role;

-- nightly, after the 2-day history sweep (05:32); converges a bounded batch
do $$ begin perform cron.unschedule('truxon-eld-gapfill'); exception when others then null; end $$;
select cron.schedule('truxon-eld-gapfill', '50 5 * * *',
  $job$select app_private.cron_edge_call('eld-sync', '{"mode":"gapfill"}'::jsonb)$job$);

-- Gapfill tuning after the first live drain: a full driving day's breadcrumb
-- fetch can eat most of one edge invocation, so convergence is ~1-3 days per
-- run, not 20. Fix the cadence, not the claim: run every 2 hours with a small
-- batch (the backlog burns down in days and the job is a no-op once caught
-- up), and fill NEWEST days first — recent days feed scorecards and the
-- no-mileage sentinels; February can wait.
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
   order by 3 desc, 2;
$$;
revoke all on function public.eld_gap_days(int) from public, anon, authenticated;
grant execute on function public.eld_gap_days(int) to service_role;

do $$ begin perform cron.unschedule('truxon-eld-gapfill'); exception when others then null; end $$;
select cron.schedule('truxon-eld-gapfill', '40 */2 * * *',
  $job$select app_private.cron_edge_call('eld-sync', '{"mode":"gapfill","limit":6}'::jsonb)$job$);

-- R8 Block 13 — feature bank gains telematics signals. Idle% was left out of
-- truck_weekly_features because breadcrumbs looked 2-day-ephemeral; they are
-- in fact retained, and today's backfill reaches 2026-06-29 — so idle% and
-- speeding minutes are now computable for every banked week, past included.
-- capture_truck_features gains a p_week parameter (null = last full week,
-- the cron behavior, unchanged) so history can be re-captured.
alter table public.truck_weekly_features
  add column if not exists idle_pct numeric,
  add column if not exists speeding_min numeric;

drop function if exists public.capture_truck_features();
create function public.capture_truck_features(p_week date default null)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_week date := coalesce(p_week, date_trunc('week', current_date - 7)::date);
  v_n int;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  insert into truck_weekly_features
    (week_start, truck_id, miles, mpg, reactive_count, reactive_cost, planned_cost,
     odometer, truck_age_years, idle_pct, speeding_min)
  select v_week, t.id,
         coalesce(em.mi, 0),
         case when coalesce(ft.gal, 0) > 0 and coalesce(em.mi, 0) > 0
              then round(em.mi / ft.gal, 2) end,
         coalesce(mx.rc, 0), coalesce(mx.rcost, 0), coalesce(mx.pcost, 0),
         vs.odometer,
         case when t.year is not null
              then round(extract(year from current_date) - t.year
                         + extract(doy from current_date) / 365.0, 1) end,
         tele.idle_pct, tele.speeding_min
  from trucks t
  left join lateral (
    select sum(e.miles) as mi from eld_daily_miles e
     where e.truck_id = t.id and e.day >= v_week and e.day < v_week + 7
  ) em on true
  left join lateral (
    select sum(f.gallons) as gal from fuel_transactions f
     where f.truck_id = t.id
       and f.transaction_time >= v_week and f.transaction_time < v_week + 7
       and f.fuel_type ilike '%diesel%' and f.fuel_type not ilike '%exhaust%'
  ) ft on true
  left join lateral (
    select count(*) filter (where not m.is_planned) as rc,
           coalesce(sum(m.cost) filter (where not m.is_planned), 0) as rcost,
           coalesce(sum(m.cost) filter (where m.is_planned), 0) as pcost
      from maintenance_records m
     where m.truck_id = t.id
       and m.date_completed >= v_week and m.date_completed < v_week + 7
  ) mx on true
  left join lateral (
    select s.odometer from eld_vehicle_status s
     join eld_vehicles v on v.vehicle_id = s.vehicle_id
     where v.truck_id = t.id
     order by s.ts desc limit 1
  ) vs on true
  left join lateral (
    -- breadcrumb time-weighting for THIS truck and week: idle share of
    -- engine-on time + minutes at 75+ mph (idle_summary/speeding_summary
    -- semantics, scoped so a weekly capture stays cheap)
    with pts as (
      select h.ts, h.speed, h.status,
             extract(epoch from (lead(h.ts) over (order by h.ts) - h.ts)) as gap_s
        from eld_location_history h
       where h.truck_id = t.id and h.ts >= v_week and h.ts < v_week + 7
    ), iv as (
      select least(gap_s, 900) as sec, speed, status
        from pts where gap_s is not null and gap_s between 1 and 900
    )
    select case when sum(sec) > 0
                then round(sum(sec) filter (where status = 'STATIONARY') / sum(sec) * 100, 1) end as idle_pct,
           round(coalesce(sum(sec) filter (where speed >= 75), 0) / 60.0, 1) as speeding_min
      from iv
  ) tele on true
  on conflict (week_start, truck_id) do update
     set miles = excluded.miles, mpg = excluded.mpg,
         reactive_count = excluded.reactive_count,
         reactive_cost = excluded.reactive_cost, planned_cost = excluded.planned_cost,
         odometer = excluded.odometer, idle_pct = excluded.idle_pct,
         speeding_min = excluded.speeding_min, captured_at = now();
  get diagnostics v_n = row_count;

  -- Backfill labels for weeks whose 4-week horizon has fully passed.
  update truck_weekly_features w
     set breakdown_next_4w = exists (
       select 1 from maintenance_records m
        where m.truck_id = w.truck_id and not m.is_planned
          and m.date_completed >= w.week_start + 7
          and m.date_completed < w.week_start + 35)
   where w.breakdown_next_4w is null
     and w.week_start + 35 <= current_date;

  return v_n;
end;
$$;
revoke all on function public.capture_truck_features(date) from public, anon, authenticated;
grant execute on function public.capture_truck_features(date) to service_role;

do $$ begin perform cron.unschedule('truxon-truck-features'); exception when others then null; end $$;
select cron.schedule('truxon-truck-features', '27 3 * * 1',
  $job$select public.capture_truck_features()$job$);

-- re-capture every full week the breadcrumb backfill now covers
select public.capture_truck_features(d::date)
from generate_series(date '2026-06-29', date_trunc('week', current_date - 7)::date, interval '7 days') d;

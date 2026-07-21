-- R3 #8 — breakdown-risk feature bank (#4 groundwork). Same lesson as IFTA:
-- bank the training data now or the model can never exist. Every Monday this
-- captures last week's per-truck features; the breakdown label (did a
-- reactive repair land within the next 4 weeks?) is backfilled once those
-- 4 weeks have passed. In ~2 months there is a labeled dataset to train on.
-- Idle% is deliberately absent for now: it derives from 2-day-retention
-- breadcrumbs and cannot be reconstructed for a full prior week.
create table public.truck_weekly_features (
  week_start date not null,               -- Monday, week standard
  truck_id bigint not null references public.trucks (id) on delete cascade,
  miles numeric not null default 0,       -- banked ELD miles that week
  mpg numeric,                            -- fuel gallons vs ELD miles (null until fuel covers the week)
  reactive_count int not null default 0,  -- unplanned repairs completed that week
  reactive_cost numeric not null default 0,
  planned_cost numeric not null default 0,
  odometer numeric,                       -- latest ELD odometer at capture
  truck_age_years numeric,
  breakdown_next_4w boolean,              -- LABEL: backfilled 4 weeks later
  captured_at timestamptz not null default now(),
  primary key (week_start, truck_id)
);
alter table public.truck_weekly_features enable row level security;
create policy twf_select on public.truck_weekly_features
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create function public.capture_truck_features()
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_week date := date_trunc('week', current_date - 7)::date;  -- last full Mon-Sun week
  v_n int;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  insert into truck_weekly_features
    (week_start, truck_id, miles, mpg, reactive_count, reactive_cost, planned_cost,
     odometer, truck_age_years)
  select v_week, t.id,
         coalesce(em.mi, 0),
         case when coalesce(ft.gal, 0) > 0 and coalesce(em.mi, 0) > 0
              then round(em.mi / ft.gal, 2) end,
         coalesce(mx.rc, 0), coalesce(mx.rcost, 0), coalesce(mx.pcost, 0),
         vs.odometer,
         case when t.year is not null
              then round(extract(year from current_date) - t.year
                         + extract(doy from current_date) / 365.0, 1) end
  from trucks t
  left join lateral (
    select sum(e.miles) as mi from eld_daily_miles e
     where e.truck_id = t.id and e.day >= v_week and e.day < v_week + 7
  ) em on true
  left join lateral (
    select sum(f.gallons) as gal from fuel_transactions f
     where f.truck_id = t.id
       and f.transaction_time >= v_week and f.transaction_time < v_week + 7
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
  on conflict (week_start, truck_id) do update
     set miles = excluded.miles, mpg = excluded.mpg,
         reactive_count = excluded.reactive_count,
         reactive_cost = excluded.reactive_cost, planned_cost = excluded.planned_cost,
         odometer = excluded.odometer, captured_at = now();
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
revoke all on function public.capture_truck_features() from public, anon, authenticated;
grant execute on function public.capture_truck_features() to service_role;

do $$ begin perform cron.unschedule('truxon-truck-features'); exception when others then null; end $$;
select cron.schedule('truxon-truck-features', '27 3 * * 1',
  $job$select public.capture_truck_features()$job$);

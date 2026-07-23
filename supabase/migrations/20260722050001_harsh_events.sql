-- R9 #45/#46: harsh-driving PROXY from GPS breadcrumbs. DriveHOS exposes no
-- accelerometer events, but the breadcrumb feed is dense (p90 gap 10s), so
-- large speed drops between consecutive points are a defensible proxy:
-- >=25 mph lost in <=12s (~2+ mph/s sustained) = hard braking;
-- >=20 mph gained in <=10s = hard acceleration. Banked nightly from the
-- 2-day breadcrumb window before it evaporates (same lesson as IFTA).
-- This is a PROXY - the playbook keeps OEM-grade events as not-captured.
create table if not exists public.harsh_events (
  id bigserial primary key,
  truck_id bigint references public.trucks(id) on delete cascade,
  vehicle_id uuid,
  ts timestamptz not null,
  kind text not null check (kind in ('braking','acceleration')),
  from_mph numeric,
  to_mph numeric,
  seconds numeric,
  lat numeric,
  lng numeric,
  created_at timestamptz not null default now(),
  unique (vehicle_id, ts, kind)
);
create index if not exists harsh_events_truck_ts_idx on public.harsh_events (truck_id, ts desc);
alter table public.harsh_events enable row level security;
revoke all on public.harsh_events from anon, authenticated;
grant select on public.harsh_events to authenticated;
drop policy if exists harsh_select on public.harsh_events;
create policy harsh_select on public.harsh_events
  for select to authenticated using (public.my_role() in ('admin','dispatcher','accountant'));
insert into app_private.security_baseline (kind, item)
values ('grant', 'authenticated harsh_events SELECT')
on conflict do nothing;

create or replace function public.detect_harsh_events(p_day date default (current_date - 1))
returns int
language plpgsql security definer set search_path = public
as $$
declare v_n int;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  insert into harsh_events (truck_id, vehicle_id, ts, kind, from_mph, to_mph, seconds, lat, lng)
  select h.truck_id, h.vehicle_id, h.ts,
         case when h.dv < 0 then 'braking' else 'acceleration' end,
         h.pspeed, h.speed, h.dt, h.lat, h.lng
    from (select t.truck_id, t.vehicle_id, t.ts, t.lat, t.lng, t.speed,
                 lag(t.speed) over w as pspeed,
                 t.speed - lag(t.speed) over w as dv,
                 extract(epoch from t.ts - lag(t.ts) over w) as dt
            from eld_location_history t
           where t.ts >= p_day and t.ts < p_day + 1 and t.speed is not null
          window w as (partition by t.vehicle_id order by t.ts)) h
   where h.dt between 2 and 12
     and ((h.dv <= -25 and h.pspeed >= 30) or (h.dv >= 20 and h.dt <= 10))
  on conflict (vehicle_id, ts, kind) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.detect_harsh_events(date) from public, anon, authenticated;
grant execute on function public.detect_harsh_events(date) to service_role;

-- nightly, right after the history sweep lands fresh breadcrumbs
do $$ begin perform cron.unschedule('truxon-harsh-detect'); exception when others then null; end $$;
select cron.schedule('truxon-harsh-detect', '5 6 * * *',
  $job$select public.detect_harsh_events()$job$);

-- flip the playbook metric honestly: proxy live, OEM events still external
update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'harsh_events — GPS-decel PROXY (>=25 mph lost in <=12s), banked nightly; OEM accelerometer events remain unavailable from DriveHOS'
where name ilike '%harsh%' and status <> 'live';

-- #46: harsh-braking on the weekly scorecard (driver via their week's trucks).
-- Full driver_scorecard redefinition (latest = 20260722034001).
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
                    having sum(em.miles) > 5) v) as dvir_pct,
           (select count(*) from harsh_events he
             where he.ts >= ws and he.ts < we and he.kind = 'braking'
               and he.truck_id in (select w3.truck_id from wk_loads w3
                                    where w3.driver_id = d.id and w3.truck_id is not null)) as harsh_brakes
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

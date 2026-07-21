-- R12 #6 — IFTA groundwork: bank the miles before they evaporate.
-- Discovery (2026-07-20 night): eld_location_history only holds ~2 days of
-- breadcrumbs — without a rollup, quarterly IFTA miles can never be
-- reconstructed. This nightly job preserves, per truck per day:
--   * total GPS miles (haversine, glitch/gap-guarded), and
--   * a THINNED path (~1 point/2min) so state attribution can be BACKFILLED
--     retroactively once state polygons land (PostGIS is available; loading
--     TIGER polygons needs an approved download — tracked separately).
-- The state column stays '' (unattributed) until then. Honest by design:
-- ifta_miles_status() reports exactly what is and isn't covered.

create table if not exists public.eld_daily_miles (
  day date not null,
  truck_id bigint not null references public.trucks (id) on delete cascade,
  state text not null default '',      -- '' = not yet attributed
  miles numeric not null default 0,
  points int not null default 0,
  path jsonb not null default '[]'::jsonb,  -- thinned [ts, lat, lng] triples
  created_at timestamptz not null default now(),
  primary key (day, truck_id, state)
);
alter table public.eld_daily_miles enable row level security;
-- no policies: service writes, office reads via the RPCs below

create or replace function public.rollup_eld_daily(p_day date default (current_date - 1))
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_count int := 0;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  insert into eld_daily_miles (day, truck_id, state, miles, points, path)
  select p_day, t.truck_id, '', t.miles, t.points, t.path
  from (
    with pts as (
      select h.truck_id, h.ts, h.lat, h.lng,
             lag(h.ts)  over w as pts_,
             lag(h.lat) over w as plat,
             lag(h.lng) over w as plng
        from eld_location_history h
       where h.ts >= p_day and h.ts < p_day + 1
         and h.lat is not null and h.lng is not null and h.truck_id is not null
      window w as (partition by h.truck_id order by h.ts)
    ),
    seg as (
      select truck_id, ts, lat, lng,
             case
               -- glitch/gap guard: ignore jumps over 30 min or over 60 miles
               when pts_ is null then 0
               when ts - pts_ > interval '30 minutes' then 0
               else least(coalesce(public.trux_miles(plat, plng, lat, lng), 0), 60)
             end as mi
        from pts
    ),
    thin as (
      select truck_id,
             jsonb_agg(jsonb_build_array(to_char(ts, 'HH24:MI'), round(lat::numeric, 4), round(lng::numeric, 4))
                       order by ts) filter (where keep) as path
        from (select s.*,
                     coalesce(ts - lag(ts) over (partition by truck_id order by ts)
                              >= interval '2 minutes', true) as keep
                from seg s) k
       group by truck_id
    )
    select s.truck_id,
           round(sum(s.mi), 1) as miles,
           count(*) as points,
           coalesce(th.path, '[]'::jsonb) as path
      from seg s left join thin th on th.truck_id = s.truck_id
     group by s.truck_id, th.path
  ) t
  where t.miles > 0
  on conflict (day, truck_id, state) do update
    set miles = excluded.miles, points = excluded.points, path = excluded.path;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.rollup_eld_daily(date) from public, anon, authenticated;
grant execute on function public.rollup_eld_daily(date) to service_role;

-- Coverage + honesty: what an IFTA quarter can and cannot be built from yet.
create or replace function public.ifta_miles_status()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select jsonb_build_object(
    'days_banked', count(distinct day),
    'first_day', min(day),
    'last_day', max(day),
    'total_miles', round(sum(miles), 0),
    'trucks_covered', count(distinct truck_id),
    'state_attributed_pct', round(coalesce(
        sum(miles) filter (where state <> '') / nullif(sum(miles), 0) * 100, 0), 1),
    'note', 'GPS miles bank nightly from the ~2-day ELD window. State attribution awaits state polygons; thinned daily paths are stored so it can be BACKFILLED for every banked day. Fuel side lives in fuel_ifta_summary().')
    into v from eld_daily_miles;
  return v;
end;
$$;
revoke all on function public.ifta_miles_status() from public, anon;
grant execute on function public.ifta_miles_status() to authenticated, service_role;

-- nightly at 03:07 for yesterday
do $$ begin perform cron.unschedule('truxon-eld-daily-rollup'); exception when others then null; end $$;
select cron.schedule('truxon-eld-daily-rollup', '7 3 * * *',
  $$select public.rollup_eld_daily()$$);

-- bank the two days that exist right now, before they expire
select public.rollup_eld_daily(current_date - 1);
select public.rollup_eld_daily(current_date);

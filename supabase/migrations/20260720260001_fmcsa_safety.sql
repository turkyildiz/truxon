-- FMCSA safety watch (#3). Auto-feed the carrier's FMCSA/SMS profile so a
-- deteriorating score, a lost safety rating, or a rising out-of-service rate
-- nudges the owner before it becomes an insurance/authority problem.
--
-- Reuses the existing safety_csa table (BASIC percentiles, already read by
-- Sentinel's csa_alert check) — those become LIVE once fmcsa-watch populates
-- them. Adds a dated carrier snapshot (rating, OOS rates vs national, crashes)
-- for trend/change detection, and the carrier's own USDOT to query against.

alter table public.company_settings add column if not exists usdot_number text not null default '';

create table if not exists public.carrier_safety_snapshot (
  id bigint generated always as identity primary key,
  snapshot_date date not null,                    -- FMCSA snapshot/retrieval date (dedup key)
  captured_at timestamptz not null default now(),
  dot_number text not null default '',
  legal_name text not null default '',
  safety_rating text not null default '',         -- S / C / U / '' (not rated)
  safety_rating_date date,
  review_date date,
  allowed_to_operate text not null default '',    -- Y / N
  status_code text not null default '',           -- A = active
  oos_date date,
  driver_insp int, driver_oos_insp int, driver_oos_rate numeric, driver_oos_natl numeric,
  vehicle_insp int, vehicle_oos_insp int, vehicle_oos_rate numeric, vehicle_oos_natl numeric,
  crash_total int, fatal_crash int, inj_crash int, towaway_crash int,
  total_drivers int, total_power_units int,
  iss_score int,
  mcs150_outdated boolean,
  raw jsonb,
  unique (snapshot_date)
);
create index if not exists carrier_safety_snapshot_recent_idx on public.carrier_safety_snapshot (snapshot_date desc);
alter table public.carrier_safety_snapshot enable row level security;

-- Company-sensitive: admin/dispatcher/accountant read; only the service RPC writes.
drop policy if exists carrier_safety_read on public.carrier_safety_snapshot;
create policy carrier_safety_read on public.carrier_safety_snapshot for select to authenticated
  using (public.my_role() in ('admin','accountant','dispatcher'));

-- Human-readable rating label.
create or replace function public.fmcsa_rating_label(p_rating text)
returns text language sql immutable as $$
  select case upper(coalesce(p_rating,''))
           when 'S' then 'Satisfactory'
           when 'C' then 'Conditional'
           when 'U' then 'Unsatisfactory'
           else 'Not Rated' end;
$$;

-- Ingest a parsed FMCSA pull. Called by fmcsa-watch (service role) or an admin.
-- p_snapshot: flat object keyed by this table's columns. p_basics: array of
-- {basic, percentile, measure, alert} already mapped to our BASIC codes.
create or replace function public.fmcsa_record(p_snapshot jsonb, p_basics jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_id bigint;
  v_basics int := 0;
  v_alerts int := 0;
  b jsonb;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  if p_snapshot is null then
    return jsonb_build_object('error', 'no snapshot');
  end if;

  insert into public.carrier_safety_snapshot (
    snapshot_date, dot_number, legal_name, safety_rating, safety_rating_date, review_date,
    allowed_to_operate, status_code, oos_date,
    driver_insp, driver_oos_insp, driver_oos_rate, driver_oos_natl,
    vehicle_insp, vehicle_oos_insp, vehicle_oos_rate, vehicle_oos_natl,
    crash_total, fatal_crash, inj_crash, towaway_crash, total_drivers, total_power_units,
    iss_score, mcs150_outdated, raw
  ) values (
    coalesce(nullif(p_snapshot->>'snapshot_date','')::date, current_date),
    coalesce(p_snapshot->>'dot_number',''), coalesce(p_snapshot->>'legal_name',''),
    coalesce(p_snapshot->>'safety_rating',''), nullif(p_snapshot->>'safety_rating_date','')::date,
    nullif(p_snapshot->>'review_date','')::date,
    coalesce(p_snapshot->>'allowed_to_operate',''), coalesce(p_snapshot->>'status_code',''),
    nullif(p_snapshot->>'oos_date','')::date,
    nullif(p_snapshot->>'driver_insp','')::int, nullif(p_snapshot->>'driver_oos_insp','')::int,
    nullif(p_snapshot->>'driver_oos_rate','')::numeric, nullif(p_snapshot->>'driver_oos_natl','')::numeric,
    nullif(p_snapshot->>'vehicle_insp','')::int, nullif(p_snapshot->>'vehicle_oos_insp','')::int,
    nullif(p_snapshot->>'vehicle_oos_rate','')::numeric, nullif(p_snapshot->>'vehicle_oos_natl','')::numeric,
    nullif(p_snapshot->>'crash_total','')::int, nullif(p_snapshot->>'fatal_crash','')::int,
    nullif(p_snapshot->>'inj_crash','')::int, nullif(p_snapshot->>'towaway_crash','')::int,
    nullif(p_snapshot->>'total_drivers','')::int, nullif(p_snapshot->>'total_power_units','')::int,
    nullif(p_snapshot->>'iss_score','')::int, nullif(p_snapshot->>'mcs150_outdated','')::boolean,
    p_snapshot
  )
  on conflict (snapshot_date) do update set
    captured_at = now(), dot_number = excluded.dot_number, legal_name = excluded.legal_name,
    safety_rating = excluded.safety_rating, safety_rating_date = excluded.safety_rating_date,
    review_date = excluded.review_date, allowed_to_operate = excluded.allowed_to_operate,
    status_code = excluded.status_code, oos_date = excluded.oos_date,
    driver_insp = excluded.driver_insp, driver_oos_insp = excluded.driver_oos_insp,
    driver_oos_rate = excluded.driver_oos_rate, driver_oos_natl = excluded.driver_oos_natl,
    vehicle_insp = excluded.vehicle_insp, vehicle_oos_insp = excluded.vehicle_oos_insp,
    vehicle_oos_rate = excluded.vehicle_oos_rate, vehicle_oos_natl = excluded.vehicle_oos_natl,
    crash_total = excluded.crash_total, fatal_crash = excluded.fatal_crash,
    inj_crash = excluded.inj_crash, towaway_crash = excluded.towaway_crash,
    total_drivers = excluded.total_drivers, total_power_units = excluded.total_power_units,
    iss_score = excluded.iss_score, mcs150_outdated = excluded.mcs150_outdated, raw = excluded.raw
  returning id into v_id;

  -- Upsert the BASIC scores into the existing safety_csa table.
  for b in select * from jsonb_array_elements(coalesce(p_basics, '[]'::jsonb)) loop
    if (b->>'basic') is null or (b->>'basic') = '' then continue; end if;
    insert into public.safety_csa (basic, percentile, measure, alert, updated_at)
    values (b->>'basic', nullif(b->>'percentile','')::numeric, nullif(b->>'measure','')::numeric,
            coalesce((b->>'alert')::boolean, false), now())
    on conflict (basic) do update set
      percentile = excluded.percentile, measure = excluded.measure,
      alert = excluded.alert, updated_at = now();
    v_basics := v_basics + 1;
    if coalesce((b->>'alert')::boolean, false) then v_alerts := v_alerts + 1; end if;
  end loop;

  return jsonb_build_object('snapshot_id', v_id, 'rating', p_snapshot->>'safety_rating',
                            'basics', v_basics, 'alerts', v_alerts);
end;
$$;
revoke all on function public.fmcsa_record(jsonb, jsonb) from public, anon;

-- Latest snapshot + current BASICs, for the Safety card. Admin/dispatcher/accountant.
create or replace function public.carrier_safety_latest()
returns jsonb
language sql security definer set search_path = public stable as $$
  select case when public.my_role() not in ('admin','accountant','dispatcher') then
    jsonb_build_object('error','forbidden')
  else jsonb_build_object(
    'snapshot', (select to_jsonb(s) - 'raw' from public.carrier_safety_snapshot s order by snapshot_date desc limit 1),
    'rating_label', (select public.fmcsa_rating_label(s.safety_rating) from public.carrier_safety_snapshot s order by snapshot_date desc limit 1),
    'basics', coalesce((select jsonb_agg(to_jsonb(c) order by c.percentile desc nulls last) from public.safety_csa c), '[]'::jsonb),
    'usdot', (select usdot_number from public.company_settings where id = 1)
  ) end;
$$;
revoke all on function public.carrier_safety_latest() from public, anon;
grant execute on function public.carrier_safety_latest() to authenticated;

-- Weekly pull (FMCSA SMS refreshes ~monthly; weekly is ample). Same anon-bearer
-- cron pattern as the other jobs.
do $$ begin perform cron.unschedule('truxon-fmcsa-watch'); exception when others then null; end $$;
select cron.schedule(
  'truxon-fmcsa-watch',
  '17 6 * * 1',   -- Mondays 06:17
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/fmcsa-watch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 280000
  );
  $$
);

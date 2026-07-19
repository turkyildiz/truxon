-- Safety & compliance module — the first Owner's-Playbook data gap to be
-- instrumented (metrics 71-85: accidents, OOS, HOS, claims, CSA). Truxon can
-- now capture these so Trux stops answering "not captured yet" for safety.

create table if not exists public.safety_events (
  id bigint generated always as identity primary key,
  event_type text not null check (event_type in ('accident','inspection','violation','claim','citation')),
  event_date date not null,
  driver_id bigint references public.drivers (id),
  truck_id bigint references public.trucks (id),
  location text not null default '',
  description text not null default '',
  severity text not null default 'minor' check (severity in ('minor','major','critical')),
  preventable boolean not null default false,
  out_of_service boolean not null default false,
  -- FMCSA CSA BASIC category for violations/inspections:
  csa_basic text not null default '' check (csa_basic in ('','unsafe_driving','hos','driver_fitness','controlled_substances','vehicle_maint','hazmat','crash')),
  claim_amount numeric(12,2) not null default 0,
  status text not null default 'open' check (status in ('open','closed')),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists safety_events_date_idx on public.safety_events (event_date desc);
create index if not exists safety_events_driver_idx on public.safety_events (driver_id);

-- Company CSA BASIC percentiles (updated from the FMCSA SMS periodically).
create table if not exists public.safety_csa (
  basic text primary key check (basic in ('unsafe_driving','hos','driver_fitness','controlled_substances','vehicle_maint','hazmat','crash')),
  percentile numeric(5,1),                          -- 0-100; higher = worse
  measure numeric,
  alert boolean not null default false,             -- over FMCSA intervention threshold
  updated_at timestamptz not null default now()
);

alter table public.safety_events enable row level security;
alter table public.safety_csa enable row level security;

-- Safety is company-sensitive: admin/dispatcher manage it, accountant reads.
drop policy if exists safety_events_read on public.safety_events;
create policy safety_events_read on public.safety_events for select to authenticated
  using (public.my_role() in ('admin','accountant','dispatcher'));
drop policy if exists safety_events_write on public.safety_events;
create policy safety_events_write on public.safety_events for all to authenticated
  using (public.my_role() in ('admin','dispatcher')) with check (public.my_role() in ('admin','dispatcher'));

drop policy if exists safety_csa_read on public.safety_csa;
create policy safety_csa_read on public.safety_csa for select to authenticated
  using (public.my_role() in ('admin','accountant','dispatcher'));
drop policy if exists safety_csa_write on public.safety_csa;
create policy safety_csa_write on public.safety_csa for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

create trigger safety_events_touch before update on public.safety_events
  for each row execute function public.touch_updated_at();

-- Safety summary over a window: accident rates per million miles (using loaded+
-- empty miles from completed/billed loads as the exposure base), OOS rate,
-- HOS violations, claims frequency/severity, plus current CSA alert count.
create or replace function public.safety_summary(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  exp_mi numeric; accidents int; preventable int; oos int; inspections int;
  hos int; claims int; claim_total numeric; open_critical int; csa_alerts int;
begin
  if public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(miles + coalesce(empty_miles,0)),0) into exp_mi from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;

  select
    count(*) filter (where e.event_type='accident'),
    count(*) filter (where e.event_type='accident' and e.preventable),
    count(*) filter (where e.out_of_service),
    count(*) filter (where e.event_type='inspection'),
    count(*) filter (where e.event_type='violation' and e.csa_basic='hos'),
    count(*) filter (where e.event_type='claim'),
    coalesce(sum(e.claim_amount) filter (where e.event_type='claim'),0),
    count(*) filter (where e.severity='critical' and e.status='open')
  into accidents, preventable, oos, inspections, hos, claims, claim_total, open_critical
  from public.safety_events e where e.event_date >= p_start::date and e.event_date < p_end::date;

  select count(*) into csa_alerts from public.safety_csa where alert;

  return jsonb_build_object(
    'exposure_miles', exp_mi,
    'accidents', accidents,
    'preventable_accidents', preventable,
    'accidents_per_million_miles', case when exp_mi>0 then round(accidents/exp_mi*1000000,2) end,
    'preventable_per_million_miles', case when exp_mi>0 then round(preventable/exp_mi*1000000,2) end,
    'inspections', inspections,
    'out_of_service_events', oos,
    'out_of_service_rate_pct', case when inspections>0 then round(oos::numeric/inspections*100,1) end,
    'hos_violations', hos,
    'claims', claims,
    'claims_total', round(claim_total,2),
    'avg_claim_severity', case when claims>0 then round(claim_total/claims,2) end,
    'open_critical_events', open_critical,
    'csa_basics_in_alert', csa_alerts
  );
end;
$$;

revoke execute on function public.safety_summary(timestamptz, timestamptz) from public, anon;
grant execute on function public.safety_summary(timestamptz, timestamptz) to authenticated;

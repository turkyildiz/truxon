-- TABLET DAY — NWS weather alerts along the fleet's actual positions.
-- api.weather.gov is US-government public domain; the weather-watch edge
-- function polls active severe alerts at each moving truck's location every
-- 30 min and pushes "winter storm ahead" to that driver's tablet. This
-- table is the exactly-once ledger (one push per alert per truck).
create table public.weather_alerts (
  id bigint generated always as identity primary key,
  alert_id text not null,               -- NWS alert id
  truck_id bigint not null references public.trucks (id) on delete cascade,
  driver_user_id uuid,
  event text not null,
  severity text not null,
  headline text not null default '',
  area text not null default '',
  expires_at timestamptz,
  pushed boolean not null default false,
  created_at timestamptz not null default now(),
  unique (alert_id, truck_id)
);
alter table public.weather_alerts enable row level security;
create policy weather_alerts_select on public.weather_alerts
  for select to authenticated
  using (
    public.my_role() in ('admin', 'dispatcher', 'accountant')
    or driver_user_id = auth.uid()
  );

do $$ begin perform cron.unschedule('truxon-weather-watch'); exception when others then null; end $$;
select cron.schedule('truxon-weather-watch', '*/30 * * * *',
  $job$select app_private.cron_edge_call('weather-watch', '{}'::jsonb)$job$);

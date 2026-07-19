-- Watchdog v2 ledger + probes: rate-limit counting, the incident feed's
-- admin gate, and the DB-probe RPC's GPS/backup/invoice signals.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

-- ---------- seed ----------
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f06'::uuid, 'wd-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f06';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f06"}', true);

-- ---------- rate-limit counting ----------
insert into public.watchdog_incidents (check_name, severity, detail) values ('inbox_poll_fresh', 'warn', 'stuck');
insert into public.watchdog_remediations (check_name, action_key, tier, status, created_at)
  values ('inbox_poll_fresh', 'reset_inbox_poll_throttle', 'auto', 'verified', now()),
         ('inbox_poll_fresh', 'reset_inbox_poll_throttle', 'auto', 'reverted', now()),
         ('inbox_poll_fresh', 'reset_inbox_poll_throttle', 'auto', 'verified', now() - interval '2 hours'),
         ('inbox_poll_fresh', 'reset_inbox_poll_throttle', 'auto', 'proposed', now());

select is(
  public.watchdog_action_count('reset_inbox_poll_throttle', 60),
  2,
  'action count in the last hour counts only ran (applied/verified/reverted/failed) rows'
);
select is(
  public.watchdog_action_count('reset_inbox_poll_throttle', 180),
  3,
  'a wider window includes the older run'
);
select is(
  public.watchdog_action_count('never_run', 60),
  0,
  'unknown action counts zero'
);

-- ---------- incident feed admin gate ----------
select is(
  (select count(*)::int from public.watchdog_incident_feed(50)),
  1,
  'admin sees the open incident in the feed'
);

update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000f06';
select is(
  (select count(*)::int from public.watchdog_incident_feed(50)),
  0,
  'non-admin sees nothing from the incident feed'
);
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f06';

-- ---------- DB probes ----------
-- Backup: no heartbeat yet ⇒ stale.
select is(
  (public.watchdog_db_probes() ->> 'backup_stale')::boolean,
  true,
  'missing backup heartbeat reads as stale'
);
insert into public.watchdog_heartbeats (source, last_seen) values ('backup', now());
select is(
  (public.watchdog_db_probes() ->> 'backup_stale')::boolean,
  false,
  'a fresh backup heartbeat clears the stale flag'
);

-- GPS: an on-duty driver with no recent position is stale; a fresh fix clears it.
insert into public.customers (company_name) values ('WD Broker');
insert into public.drivers (full_name) values ('WD Driver');
insert into public.driver_duty (driver_id, is_on_duty, on_duty_since)
  select id, true, now() from public.drivers where full_name = 'WD Driver';
select is(
  (public.watchdog_db_probes(15) ->> 'gps_stale')::int,
  1,
  'on-duty driver with no position counts as GPS-stale'
);

insert into public.vehicle_position_current (driver_id, lat, lng, recorded_at)
  select id, 41.0, -81.0, now() from public.drivers where full_name = 'WD Driver';
select is(
  (public.watchdog_db_probes(15) ->> 'gps_stale')::int,
  0,
  'a recent position clears the GPS-stale count'
);

select * from finish();
rollback;

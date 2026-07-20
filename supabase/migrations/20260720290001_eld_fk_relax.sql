-- ELD status/history should never be blocked by roster-load ordering or a
-- vehicle/driver that reports before it's in the roster page. Drop the FKs to the
-- rosters (keep the columns + indexes); the sync backfills roster stubs anyway.
alter table public.eld_vehicle_status  drop constraint if exists eld_vehicle_status_vehicle_id_fkey;
alter table public.eld_driver_status   drop constraint if exists eld_driver_status_driver_id_fkey;
alter table public.eld_location_history drop constraint if exists eld_location_history_vehicle_id_fkey;

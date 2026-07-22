-- Follow-up incident fix: sentinel_scan started dying with "canceling
-- statement due to statement timeout" once it ran again. Two compounding
-- causes from today: the GPS backfill tripled eld_location_history (137K →
-- 411K rows), slowing every breadcrumb-window check (idle, detention,
-- on-time), and the new idle check added ~2s itself. The minted-admin session
-- runs under the authenticated role's ~8s default statement_timeout.
--
-- The scan is a 15-minute background job, not an interactive query — give it
-- real headroom, and give the time-window scans an index on ts alone (the
-- existing indexes lead with vehicle_id/truck_id, useless for "last N days
-- across the fleet" predicates).
alter function public.sentinel_scan() set statement_timeout to '120s';

create index if not exists eld_loc_ts_idx on public.eld_location_history (ts desc);

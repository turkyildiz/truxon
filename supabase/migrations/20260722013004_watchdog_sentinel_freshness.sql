-- Close the "silently dead sentinel" class for good. Today the sentinel was
-- down 20.5h (03:06Z → 23:32Z) while pg_cron logged "succeeded" every 15 min —
-- cron only records that the HTTP call was queued, and nothing watched whether
-- scans actually LANDED. The watchdog now probes the effect, not the trigger:
-- trux_insights.last_seen must move every scan. Stale > 2h during a period
-- with any open findings ⇒ the scan pipeline is broken somewhere (edge fn,
-- admin mint, RPC timeout — today hit all three).
create or replace function public.watchdog_db_probes(p_gps_stale_min int default 15, p_backup_stale_hours int default 26)
returns jsonb
language sql stable security definer set search_path = public, cron
as $$
  select jsonb_build_object(
    -- GPS: on-duty drivers whose latest fix is missing or older than the window.
    'gps_on_duty', (select count(*)::int from public.driver_duty where is_on_duty),
    'gps_stale', (
      select count(*)::int from public.driver_duty dd
       where dd.is_on_duty
         and not exists (
           select 1 from public.vehicle_position_current vpc
            where vpc.driver_id = dd.driver_id
              and vpc.recorded_at > now() - make_interval(mins => p_gps_stale_min))),
    -- Invoice numbering integrity canaries.
    'invoice_dupes', (
      select count(*)::int from (
        select invoice_number from public.invoices
         where status <> 'void' group by invoice_number having count(*) > 1) d),
    'invoice_seq_behind', (
      select coalesce(
        (select last_value from public.invoice_number_seq)
          < (select coalesce(max((regexp_match(invoice_number, '^INV-\d{4}-(\d+)$'))[1]::bigint), 0)
               from public.invoices), false)),
    -- Inbox rows wedged mid-processing beyond a poll cycle.
    'stuck_processing', (
      select count(*)::int from public.trux_inbox_log
       where status = 'processing' and created_at < now() - interval '15 minutes'),
    -- Backup heartbeat freshness.
    'backup_stale', (
      select coalesce(
        (select last_seen from public.watchdog_heartbeats where source = 'backup')
          < now() - make_interval(hours => p_backup_stale_hours),
        true)),
    'backup_last_seen', (select last_seen from public.watchdog_heartbeats where source = 'backup'),
    -- GPU box (Lynx) heartbeat freshness — NULL until it first posts (no pre-setup alarm).
    'gpu_box_stale', (
      select (last_seen < now() - interval '20 minutes')
        from public.watchdog_heartbeats where source = 'lynx'),
    'gpu_box_last_seen', (select last_seen from public.watchdog_heartbeats where source = 'lynx'),
    -- Sentinel scans must LAND, not merely be queued: last_seen moves on every
    -- 15-min scan, so >2h stale with findings on the books = pipeline dead.
    'sentinel_stale', (
      select (max(last_seen) < now() - interval '2 hours')
        from public.trux_insights),
    'sentinel_last_scan', (select max(last_seen) from public.trux_insights)
  );
$$;

grant execute on function public.watchdog_db_probes(int, int) to service_role;

-- GPU box (Lynx) heartbeat monitoring. Lynx posts a {heartbeat:'lynx'} ping every
-- few minutes (same door as the NAS backup heartbeat). This redefines
-- watchdog_db_probes to also surface Lynx freshness so the watchdog can warn when
-- the GPU box goes dark (vision/embeddings/heavy-LLM degrade to NAS fallback).
-- gpu_box_stale is NULL until Lynx first posts, so it never false-alarms pre-setup.
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
    'gpu_box_last_seen', (select last_seen from public.watchdog_heartbeats where source = 'lynx')
  );
$$;

grant execute on function public.watchdog_db_probes(int, int) to service_role;

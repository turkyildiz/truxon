-- ============================================================================
-- Ransomware guard, DML layer (JadePuffer / ENCFORGE follow-up).
-- The DDL guard (20260722003001) blocks DROP/TRUNCATE. It deliberately does NOT
-- cover row-level destruction. This closes that gap:
--   • mass DELETE  → BLOCKED. Truxon never hard-deletes crown-jewel rows in bulk
--     (it voids/soft-deletes), so a statement deleting many rows is an attack.
--   • mass UPDATE  → ALARM-ONLY. Legit bulk updates DO happen (QBO sync, back-
--     fills), so blocking would break prod; instead we flag an abnormally large
--     single-statement update (the "encrypt cells in place" pattern) for review.
-- Both use statement-level triggers with transition tables. Triggers are owned
-- by postgres, so the exposed service-key/authenticator roles can't drop them
-- (same protection basis as the TRUNCATE guard). Legit maintenance sets
-- `app.allow_bulk_dml = on`.
-- ============================================================================

-- Out-of-band + in-band recorder. The DELETE path calls it via dblink (its own
-- txn is about to roll back); the UPDATE path calls it directly (that txn
-- commits). Wording reflects whether the op was blocked.
create or replace function app_private.dml_guard_record(
  p_object text, p_op text, p_rows int, p_blocked boolean)
returns void
language plpgsql security definer set search_path = public, app_private
as $$
begin
  perform app_private.audit(
    case when p_blocked then 'destructive_dml_blocked' else 'bulk_dml_detected' end,
    'critical',
    jsonb_build_object('object', p_object, 'op', p_op, 'rows', p_rows, 'blocked', p_blocked));

  insert into public.trux_insights (dedup_key, category, severity, title, detail, entity_type)
  values (
    'ransom_dml:' || p_op || ':' || p_object || ':' || to_char(now(),'YYYYMMDDHH24MI'),
    'compliance', 'critical',
    case when p_blocked
      then '🧨 Blocked a mass ' || p_op || ' on ' || p_object
      else '⚠️ Unusually large ' || p_op || ' (' || p_rows || ' rows) on ' || p_object end,
    case when p_blocked
      then 'A single statement tried to ' || p_op || ' ' || p_rows || ' rows from "' || p_object || '" — a '
        || 'mass-destruction pattern (ransomware wiping data row-by-row to dodge the DROP/TRUNCATE guard). '
        || 'Truxon BLOCKED it and rolled it back; no rows were lost. Treat as an ACTIVE intrusion: engage '
        || 'lockdown, check the security audit log, rotate the service key + DB password, verify backups. '
        || 'Runbook: deploy/SECURITY_RUNBOOK.md.'
      else 'A single statement updated ' || p_rows || ' rows of "' || p_object || '" at once — larger than any '
        || 'normal Truxon operation. This can be a legitimate bulk backfill, or ransomware encrypting cells in '
        || 'place. It was ALLOWED (updates are not auto-blocked, to protect legitimate syncs) but flagged. If '
        || 'you did not run a bulk update, treat as an intrusion and verify the rows against backups. Silence '
        || 'expected backfills by running them with app.allow_bulk_dml = on.'
    end,
    'security')
  on conflict (dedup_key) do nothing;

  begin perform app_private.cron_edge_call('trux-sentinel', '{"mode":"scan"}'::jsonb); exception when others then null; end;
end;
$$;
revoke all on function app_private.dml_guard_record(text, text, int, boolean) from public, anon, authenticated;

-- BLOCKING mass-DELETE guard.
create or replace function public.guard_bulk_delete()
returns trigger
language plpgsql security definer set search_path = public, app_private
as $$
declare v_cnt int; v_dsn text; v_thresh int := 100;
begin
  if lower(coalesce(current_setting('app.allow_bulk_dml', true),'')) in ('on','true','1','yes') then
    return null;
  end if;
  select count(*) into v_cnt from deleted;
  if v_cnt > v_thresh then
    select value into v_dsn from app_private.cron_config where key = 'hp_dsn';
    if coalesce(v_dsn,'') <> '' then
      begin
        perform extensions.dblink_exec(v_dsn,
          format('select app_private.dml_guard_record(%L, %L, %s, %L)',
                 'public.'||tg_table_name, 'DELETE', v_cnt, true));
      exception when others then null;
      end;
    end if;
    raise exception 'BLOCKED by ransomware guard: bulk DELETE of % rows on % is not permitted. '
      '(Legitimate maintenance? set app.allow_bulk_dml = on.)', v_cnt, tg_table_name;
  end if;
  return null;
end;
$$;

-- ALARM-ONLY mass-UPDATE detector.
create or replace function public.guard_bulk_update()
returns trigger
language plpgsql security definer set search_path = public, app_private
as $$
declare v_cnt int; v_thresh int := 500;
begin
  if lower(coalesce(current_setting('app.allow_bulk_dml', true),'')) in ('on','true','1','yes') then
    return null;
  end if;
  select count(*) into v_cnt from updated;
  if v_cnt > v_thresh then
    perform app_private.dml_guard_record('public.'||tg_table_name, 'UPDATE', v_cnt, false);
  end if;
  return null;
end;
$$;

-- Wire both onto the crown jewels. trux_insights is intentionally excluded — the
-- sentinel legitimately bulk-resolves findings there.
do $$
declare t text;
begin
  foreach t in array array['invoices','loads','customers','fuel_transactions',
                           'toll_transactions','drivers','trucks']
  loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists guard_bulk_delete_t on public.%I', t);
      execute format('create trigger guard_bulk_delete_t after delete on public.%I '
                     'referencing old table as deleted '
                     'for each statement execute function public.guard_bulk_delete()', t);
      execute format('drop trigger if exists guard_bulk_update_t on public.%I', t);
      execute format('create trigger guard_bulk_update_t after update on public.%I '
                     'referencing new table as updated '
                     'for each statement execute function public.guard_bulk_update()', t);
    end if;
  end loop;
end $$;

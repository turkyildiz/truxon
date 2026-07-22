-- ============================================================================
-- Ransomware guard (JadePuffer / ENCFORGE class defense).
-- Agentic ransomware's final move is destroying the production database:
-- DROP TABLE / DROP SCHEMA / TRUNCATE, often after stealing a credential that
-- grants broad DB access. Truxon's most-exposed such credential is the Supabase
-- SERVICE KEY (present in every edge-function env). This guard makes that
-- credential — and any authenticated/service DB session — UNABLE to destroy the
-- schema: a database event trigger blocks destructive DDL and rolls it back,
-- while recording the attempt out-of-band (via the honeypot dblink, so the
-- alarm survives the rollback the block causes) as a critical Forest finding.
--
-- Scope & honesty: this stops the service-key path and any PostgREST role. A
-- full `postgres`/DB-URL compromise (that credential lives only in the NAS
-- backup.env, far less exposed) could DISABLE the trigger first — but that is
-- audited-adjacent, noisy, and the immutable NAS pull-backups guarantee
-- recovery regardless. Legit schema changes set `app.allow_drops = on`.
-- DML-level destruction (mass DELETE/encrypt) is covered by backups + the audit
-- log + honeytokens, not by this trigger.
-- ============================================================================

-- Out-of-band recorder: called via dblink from the guard so its writes COMMIT
-- independently of the transaction the guard is about to roll back.
create or replace function app_private.ransom_guard_record(p_object text, p_op text)
returns void
language plpgsql security definer set search_path = public, app_private
as $$
begin
  perform app_private.audit('destructive_ddl_blocked', 'critical',
    jsonb_build_object('object', p_object, 'op', p_op));
  insert into public.trux_insights (dedup_key, category, severity, title, detail, entity_type)
  values ('ransom_ddl:' || p_object || ':' || to_char(now(),'YYYYMMDDHH24MI'),
          'compliance', 'critical',
          '🧨 Blocked a destructive operation on ' || p_object,
          'Something tried to ' || p_op || ' "' || p_object || '" — the signature move of ransomware and '
            || 'data-destruction attacks (e.g. the JadePuffer/ENCFORGE agentic ransomware). Truxon''s guard '
            || 'BLOCKED it and rolled it back; no data was lost and no legitimate Truxon code drops tables. '
            || 'Treat this as an ACTIVE intrusion: engage lockdown, check the security audit log, rotate the '
            || 'service key + database password, and verify backups. Runbook: deploy/SECURITY_RUNBOOK.md.',
          'security')
  on conflict (dedup_key) do nothing;
  begin perform app_private.cron_edge_call('trux-sentinel', '{"mode":"scan"}'::jsonb); exception when others then null; end;
end;
$$;
revoke all on function app_private.ransom_guard_record(text, text) from public, anon, authenticated;

-- The DROP guard.
create or replace function app_private.guard_destructive_ddl()
returns event_trigger
language plpgsql security definer set search_path = public, app_private
as $$
declare
  r record;
  v_dsn text;
  v_bypass text := lower(coalesce(current_setting('app.allow_drops', true), ''));
begin
  if v_bypass in ('on','true','1','yes') then return; end if;   -- explicit migration override
  select value into v_dsn from app_private.cron_config where key = 'hp_dsn';
  -- Note: the guard can't block its OWN drop (Postgres doesn't fire an event
  -- trigger for its removal), but it doesn't need to — event triggers can only
  -- be dropped by their owner (postgres). The exposed service-key/authenticator
  -- roles cannot remove it; only a postgres/DB-URL compromise could.
  for r in select * from pg_event_trigger_dropped_objects() loop
    if not r.is_temporary and r.schema_name = 'public' and r.object_type in ('table','schema') then
      if coalesce(v_dsn,'') <> '' then
        begin
          perform extensions.dblink_exec(v_dsn,
            format('select app_private.ransom_guard_record(%L, %L)', r.object_identity, tg_tag));
        exception when others then null;
        end;
      end if;
      raise exception 'BLOCKED by ransomware guard: % on "%" is not permitted. '
        '(Legitimate schema change? set app.allow_drops = on in the migration.)', tg_tag, r.object_identity;
    end if;
  end loop;
end;
$$;
drop event trigger if exists guard_destructive_ddl_trg;
create event trigger guard_destructive_ddl_trg on sql_drop
  execute function app_private.guard_destructive_ddl();

-- TRUNCATE guard on the crown-jewel tables (sql_drop doesn't cover TRUNCATE).
create or replace function public.guard_truncate()
returns trigger
language plpgsql security definer set search_path = public, app_private
as $$
declare v_dsn text;
begin
  if lower(coalesce(current_setting('app.allow_drops', true),'')) in ('on','true','1','yes') then
    return null;
  end if;
  select value into v_dsn from app_private.cron_config where key = 'hp_dsn';
  if coalesce(v_dsn,'') <> '' then
    begin
      perform extensions.dblink_exec(v_dsn,
        format('select app_private.ransom_guard_record(%L, %L)', 'public.'||tg_table_name, 'TRUNCATE'));
    exception when others then null;
    end;
  end if;
  raise exception 'BLOCKED by ransomware guard: TRUNCATE on % is not permitted.', tg_table_name;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['invoices','loads','customers','fuel_transactions',
                           'toll_transactions','trux_insights','drivers','trucks']
  loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists guard_truncate_t on public.%I', t);
      execute format('create trigger guard_truncate_t before truncate on public.%I '
                     'for each statement execute function public.guard_truncate()', t);
    end if;
  end loop;
end $$;

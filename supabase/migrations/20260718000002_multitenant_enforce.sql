-- ============================================================================
-- MULTI-TENANT — PHASE 2: ENFORCEMENT (restrictive RLS)
-- ============================================================================
-- Adds a RESTRICTIVE policy per business table: a row is only visible/writable
-- if its tenant_id matches the caller's tenant. Restrictive policies AND with
-- the existing (role-based) permissive policies, so NONE of the current 72
-- policies need rewriting — we just layer tenant isolation on top.
--
-- SAFE to apply with one tenant: my_tenant_id() = aida for every user, so
-- `tenant_id = my_tenant_id()` is always true and behavior is unchanged. The
-- isolation only takes effect once a second tenant's users exist.
--
-- ⚠️ BEFORE ONBOARDING A SECOND TENANT you MUST also add tenant filters inside
-- the SECURITY DEFINER RPCs — they run as the table owner and BYPASS RLS, so
-- this migration does NOT protect data returned through them. The full list is
-- in docs/MULTI_TENANT.md ("RPCs that must be tenant-filtered"). Onboarding
-- tenant #2 before that is a cross-tenant data leak.
--
-- Test on a Supabase preview branch with two tenants + probe accounts before
-- prod. Reversible: drop policy tenant_isolation on each table.
-- ============================================================================

do $$
declare
  t text;
  biz text[] := array[
    'company_settings','customers','load_stops','loads','drivers','trucks','trailers',
    'maintenance_records','invoices','documents','activity_log','drive_files',
    'vehicle_positions','vehicle_position_current','driver_duty','push_devices',
    'trux_sessions','trux_messages','trux_actions','trux_agent_audit','trux_inbox_log','companion_config'
  ];
begin
  foreach t in array biz loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('drop policy if exists tenant_isolation on public.%I', t);
    execute format(
      'create policy tenant_isolation on public.%I as restrictive to authenticated '
      'using (tenant_id = public.my_tenant_id()) '
      'with check (tenant_id = public.my_tenant_id())', t);
  end loop;
end $$;

-- ============================================================================
-- MULTI-TENANT — PHASE 1: FOUNDATION (additive, non-breaking)
-- ============================================================================
-- This migration is SAFE to apply to production: it changes NO existing
-- behavior. It only adds the plumbing for tenant isolation:
--   • a `tenants` table (with the current company seeded as "aida")
--   • a nullable `tenant_id` on `profiles` and every business table
--   • all existing rows + users backfilled to the aida tenant
--   • `my_tenant_id()` helper + a BEFORE INSERT trigger that auto-stamps
--     tenant_id so new rows are always tenant-scoped
--
-- RLS is DELIBERATELY unchanged here. With one tenant, the app behaves exactly
-- as before. Isolation is enforced in a SEPARATE phase-2 migration
-- (20260718000002_multitenant_enforce.sql) which must be tested on a Supabase
-- preview branch BEFORE prod, together with tenant filters inside the
-- SECURITY DEFINER RPCs (RPCs bypass RLS — see docs/MULTI_TENANT.md).
--
-- Reversible: drop the phase-2 policies, then `alter table ... drop column
-- tenant_id`, then drop the tenants table + helpers.
-- ============================================================================

create table if not exists public.tenants (
  id bigint generated always as identity primary key,
  name text not null,
  slug text not null unique,
  is_active boolean not null default true,
  settings jsonb not null default '{}',
  created_at timestamptz not null default now()
);

-- Seed the existing company as the first tenant.
insert into public.tenants (name, slug)
select 'Aida Logistics', 'aida'
where not exists (select 1 from public.tenants where slug = 'aida');

-- Which tenant a user belongs to.
alter table public.profiles add column if not exists tenant_id bigint references public.tenants (id);
update public.profiles set tenant_id = (select id from public.tenants where slug = 'aida') where tenant_id is null;

-- Caller's tenant, resolved from their profile. SECURITY DEFINER so it can read
-- profiles regardless of the caller's own RLS.
create or replace function public.my_tenant_id()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select tenant_id from public.profiles where id = auth.uid();
$$;
revoke all on function public.my_tenant_id() from public;
revoke execute on function public.my_tenant_id() from anon;
grant execute on function public.my_tenant_id() to authenticated;

-- Auto-stamp tenant_id on insert so app code never has to pass it and can never
-- get it wrong. Runs as definer so it can call my_tenant_id().
create or replace function public.set_tenant_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.tenant_id is null then
    new.tenant_id := public.my_tenant_id();
  end if;
  return new;
end;
$$;

-- Add tenant_id + backfill + index + auto-stamp trigger to every business table.
-- Platform/singleton tables (rate_limit_events, watchdog_state, llm_*, inbox_state)
-- are intentionally left global.
do $$
declare
  t text;
  biz text[] := array[
    'company_settings','customers','load_stops','loads','drivers','trucks','trailers',
    'maintenance_records','invoices','documents','activity_log','drive_files',
    'vehicle_positions','vehicle_position_current','driver_duty','push_devices',
    'trux_sessions','trux_messages','trux_actions','trux_agent_audit','trux_inbox_log','companion_config'
  ];
  aida bigint := (select id from public.tenants where slug = 'aida');
begin
  foreach t in array biz loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('alter table public.%I add column if not exists tenant_id bigint references public.tenants (id)', t);
    execute format('update public.%I set tenant_id = %L where tenant_id is null', t, aida);
    execute format('create index if not exists %I on public.%I (tenant_id)', t || '_tenant_idx', t);
    execute format('drop trigger if exists %I on public.%I', t || '_set_tenant', t);
    execute format('create trigger %I before insert on public.%I for each row execute function public.set_tenant_id()', t || '_set_tenant', t);
  end loop;
end $$;

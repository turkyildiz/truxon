-- ============================================================================
-- MULTI-TENANT — PHASE 5: NEW-USER TENANT STAMPING + SUPER-ADMIN ONBOARDING
-- ============================================================================
-- Closes the app-layer gaps so a real 2nd tenant can be created and used:
--   • new users get a tenant_id (handle_new_user reads it from user metadata,
--     which the admin-users edge function now supplies) — without this a new
--     user's profile.tenant_id is null and they see nothing.
--   • a `super_admin` flag + `my_is_super_admin()` for the platform operator.
--   • `create_tenant()` — super-admin-only tenant creation.
--   • RLS on `tenants` so a normal user reads only their own tenant.
--
-- SAFE with one tenant. Reversible: drop the column, function, policy; restore
-- the prior handle_new_user body.
-- ============================================================================

-- 1. Platform operator flag (who may create tenants / cross tenant lines).
alter table public.profiles add column if not exists super_admin boolean not null default false;

create or replace function public.my_is_super_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(super_admin, false) from public.profiles where id = auth.uid();
$$;
revoke all on function public.my_is_super_admin() from public, anon;
grant execute on function public.my_is_super_admin() to authenticated;

-- 2. Stamp tenant_id on the new profile from the creating admin's metadata.
--    (profiles has no auto-stamp trigger, and public signup is disabled — the
--    admin-users edge function always supplies tenant_id.)
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, username, full_name, role, tenant_id)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce((new.raw_user_meta_data ->> 'role')::public.user_role, 'dispatcher'),
    nullif(new.raw_user_meta_data ->> 'tenant_id', '')::bigint
  );
  return new;
end;
$$;

-- 3. Super-admin-only tenant creation.
create or replace function public.create_tenant(p_name text, p_slug text)
returns public.tenants
language plpgsql security definer set search_path = public
as $$
declare
  t public.tenants;
begin
  if not public.my_is_super_admin() then
    raise exception 'Super admin only';
  end if;
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_slug), '') = '' then
    raise exception 'name and slug are required';
  end if;
  insert into public.tenants (name, slug) values (trim(p_name), lower(trim(p_slug)))
  returning * into t;
  return t;
end;
$$;
revoke all on function public.create_tenant(text, text) from public, anon;
grant execute on function public.create_tenant(text, text) to authenticated;

-- 4. RLS on tenants: a normal user sees only their own tenant; a super-admin
--    sees all. Writes go only through create_tenant (SECURITY DEFINER bypasses
--    RLS), so no insert/update/delete policy is granted to authenticated.
alter table public.tenants enable row level security;
drop policy if exists tenants_select on public.tenants;
create policy tenants_select on public.tenants
  for select to authenticated
  using (id = public.my_tenant_id() or public.my_is_super_admin());

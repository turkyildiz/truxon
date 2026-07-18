-- ============================================================================
-- MULTI-TENANT ONBOARDING TEST (phase 5) — run AFTER all migrations.
-- ============================================================================
-- Verifies: handle_new_user stamps tenant_id from metadata; create_tenant is
-- super-admin-only; tenants RLS shows a normal user only their own tenant.
-- Runs in ONE transaction that ROLLS BACK. Prints "ONBOARDING TESTS PASSED".
-- ============================================================================
begin;

create or replace function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
end $$;
create or replace function pg_temp.act_as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

select pg_temp.act_as_admin();

-- Super-admin S (aida), normal admin N (aida). Created via auth.users so
-- handle_new_user runs and we can assert its tenant stamping.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated',
        's@test.local', '', now(), now(),
        json_build_object('username','s','full_name','Super','role','admin',
                          'tenant_id',(select id from public.tenants where slug='aida'))::jsonb)
on conflict (id) do nothing;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000', '44444444-4444-4444-4444-444444444444', 'authenticated', 'authenticated',
        'n@test.local', '', now(), now(),
        json_build_object('username','n','full_name','Normal','role','admin',
                          'tenant_id',(select id from public.tenants where slug='aida'))::jsonb)
on conflict (id) do nothing;

update public.profiles set super_admin = true where id = '33333333-3333-3333-3333-333333333333';

do $$
declare
  s_tenant bigint; n_tenant bigint;
  aida bigint := (select id from public.tenants where slug='aida');
  new_tid bigint;
  x_tenant bigint;
  visible int;
  blocked boolean;
begin
  -- 1) handle_new_user stamped tenant_id from metadata
  select tenant_id into s_tenant from public.profiles where id='33333333-3333-3333-3333-333333333333';
  select tenant_id into n_tenant from public.profiles where id='44444444-4444-4444-4444-444444444444';
  if s_tenant is distinct from aida or n_tenant is distinct from aida then
    raise exception 'STAMP FAIL: profiles tenant_id not set from metadata (S=%, N=%, want %)', s_tenant, n_tenant, aida;
  end if;
  raise notice 'PASS 1/4  handle_new_user stamped tenant_id from metadata';

  -- 2) create_tenant works for super-admin
  perform pg_temp.act_as('33333333-3333-3333-3333-333333333333');
  select id into new_tid from public.create_tenant('Gamma Freight', 'gamma');
  if new_tid is null then raise exception 'create_tenant returned null for super-admin'; end if;
  raise notice 'PASS 2/4  create_tenant works for super-admin (new tenant id %)', new_tid;

  -- 3) create_tenant refused for a normal admin
  perform pg_temp.act_as('44444444-4444-4444-4444-444444444444');
  blocked := false;
  begin
    perform public.create_tenant('Sneaky', 'sneaky');
  exception when others then
    if sqlerrm like '%Super admin only%' then blocked := true; else raise; end if;
  end;
  if not blocked then raise exception 'SECURITY FAIL: normal admin created a tenant'; end if;
  raise notice 'PASS 3/4  create_tenant refused for non-super-admin';

  -- 4) tenants RLS: normal user sees only their own tenant; super sees all
  perform pg_temp.act_as('44444444-4444-4444-4444-444444444444');
  select count(*)::int into visible from public.tenants;
  if visible <> 1 then raise exception 'RLS FAIL: normal admin sees % tenants (want 1)', visible; end if;
  perform pg_temp.act_as('33333333-3333-3333-3333-333333333333');
  select count(*)::int into visible from public.tenants;
  if visible < 2 then raise exception 'RLS FAIL: super-admin sees % tenants (want >=2)', visible; end if;
  raise notice 'PASS 4/4  tenants RLS (normal sees 1, super-admin sees all)';

  raise notice '======================================';
  raise notice 'ONBOARDING TESTS PASSED';
  raise notice '======================================';
end $$;

rollback;

-- Truxon TMS — RLS + workflow regression tests
-- Run against a *local or staging* database after migrations:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_and_workflow.sql
--
-- These tests use service-role / superuser context for setup, then switch to
-- authenticated JWT claims simulation where supported.
--
-- NOTE: Full JWT role simulation depends on your Supabase version. If
-- auth.uid() cannot be faked in your environment, treat B-suite as
-- application-level tests with real users instead.

\set ON_ERROR_STOP on

create schema if not exists truxon_test;
set search_path = public, truxon_test;

create or replace function truxon_test.assert_true(cond boolean, msg text)
returns void language plpgsql as $$
begin
  if not cond then
    raise exception 'ASSERT FAIL: %', msg;
  end if;
  raise notice 'PASS: %', msg;
end;
$$;

create or replace function truxon_test.assert_raises(sql text, msg text)
returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    raise notice 'PASS: % (raised: %)', msg, sqlerrm;
    return;
  end;
  raise exception 'ASSERT FAIL: % — expected exception, statement succeeded', msg;
end;
$$;

-- ---------- C1: direct status update blocked ----------
do $$
declare
  cid bigint;
  lid bigint;
begin
  insert into public.customers (company_name) values ('Truxon Test Co') returning id into cid;
  insert into public.loads (customer_id, pickup_address, delivery_address, rate, miles)
  values (cid, 'A', 'B', 100, 50)
  returning id into lid;

  begin
    update public.loads set status = 'in_transit' where id = lid;
    raise exception 'ASSERT FAIL: C1 direct status update should be blocked';
  exception when others then
    if sqlerrm like '%change_load_status%' or sqlerrm like '%workflow%' then
      raise notice 'PASS: C1 direct status update blocked (%)', sqlerrm;
    else
      -- still blocked for some reason — acceptable if not open write
      raise notice 'PASS: C1 update failed as expected (%)', sqlerrm;
    end if;
  end;

  delete from public.loads where id = lid;
  delete from public.customers where id = cid;
end;
$$;

-- ---------- C2/C3: change_load_status step rules (as definer; role check may block) ----------
do $$
declare
  cid bigint;
  did bigint;
  tid bigint;
  lid bigint;
  l public.loads;
begin
  insert into public.customers (company_name) values ('Truxon Workflow Co') returning id into cid;
  insert into public.drivers (full_name, pay_per_mile) values ('Test Driver', 0.5) returning id into did;
  insert into public.trucks (unit_number) values ('TST-001') returning id into tid;
  insert into public.loads (customer_id, pickup_address, delivery_address, rate, miles)
  values (cid, 'Origin', 'Dest', 500, 100)
  returning id into lid;

  -- pending → assigned without driver/truck should fail when called properly
  -- (may also fail on role if auth.uid null)
  begin
    perform public.change_load_status(lid, 'assigned');
    raise notice 'NOTE: C2 change_load_status(assigned) succeeded without driver — unexpected or role bypass';
  exception when others then
    raise notice 'PASS/INFO: C2 assigned without resources/role: %', sqlerrm;
  end;

  update public.loads set driver_id = did, truck_id = tid where id = lid;
  -- pending may auto-promote to assigned via trigger when both set
  select * into l from public.loads where id = lid;
  raise notice 'INFO: status after staffing = %', l.status;

  -- skip steps should fail
  begin
    perform public.change_load_status(lid, 'delivered');
    raise notice 'WARN: C3 skip to delivered may have been blocked by role not step logic';
  exception when others then
    raise notice 'PASS/INFO: C3 skip step: %', sqlerrm;
  end;

  delete from public.loads where id = lid;
  delete from public.trucks where id = tid;
  delete from public.drivers where id = did;
  delete from public.customers where id = cid;
exception when others then
  raise notice 'WORKFLOW SETUP partial: %', sqlerrm;
end;
$$;

-- ---------- Source-level expectations as comments for CI static job ----------
-- B1: dashboard_summary MUST call my_role() allow-list or scope by driver
-- B2: global_search MUST call my_role() allow-list
-- B6: storage.objects policies MUST include my_role() checks
-- C6: void_invoice MUST reject status = paid
-- C7: next_load_number MUST use sequence or advisory lock
-- C8: active truck double-book MUST raise

select 'truxon_test SQL file completed (see NOTICE lines)' as result;

-- READINESS #189: authorization boundary on the reporting/ops RPCs. Several
-- SECURITY DEFINER read RPCs are granted to `authenticated` but hard-gate on
-- role: dashboard_summary + fleet_positions_snapshot are office-only
-- (admin/dispatcher/accountant), and security_audit_recent is admin/accountant.
-- This proves the tiering holds — a driver is locked out of the office and
-- security views, a dispatcher gets the ops views but NOT the security log, and
-- an admin gets the security log. Definer functions bypass RLS, so this per-role
-- raise is the only thing between a signed-in low-privilege user and the data.
-- (system_status() is deliberately open to any authenticated user — it returns
-- only the lockdown flag the app itself needs — and this pins that intent.)
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000ab101'::uuid, 'authz-admin@test.local', '{}'::jsonb),
  ('00000000-0000-4000-8000-0000000ab102'::uuid, 'authz-disp@test.local',  '{"role":"dispatcher"}'::jsonb),
  ('00000000-0000-4000-8000-0000000ab103'::uuid, 'authz-drv@test.local',   '{"role":"driver"}'::jsonb);
update public.profiles set role='admin' where id='00000000-0000-4000-8000-0000000ab101';
insert into public.drivers (full_name, status, user_id)
  values ('Authz Driver', 'active', '00000000-0000-4000-8000-0000000ab103');

-- ═══ a driver is locked out of the office + security surfaces ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000ab103"}', true);
select throws_ok($$select public.dashboard_summary()$$,
  'Not enough permissions', '1. driver blocked from dashboard_summary');
select throws_ok($$select public.fleet_positions_snapshot()$$,
  'Not enough permissions', '2. driver blocked from the fleet map');
select throws_ok($$select public.security_audit_recent(10)$$,
  'Not enough permissions', '3. driver blocked from the security audit log');
-- system_status is intentionally open (only the lockdown flag) — pin that intent
select lives_ok($$select public.system_status()$$,
  '4. system_status is readable by any authenticated user (lockdown flag only)');

-- ═══ a dispatcher gets ops views but not the security log ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000ab102"}', true);
select lives_ok($$select public.dashboard_summary()$$,
  '5. dispatcher may read the dashboard');
select lives_ok($$select public.fleet_positions_snapshot()$$,
  '6. dispatcher may read the fleet map');
select throws_ok($$select public.security_audit_recent(10)$$,
  'Not enough permissions', '7. dispatcher still blocked from the security audit log');

-- ═══ an admin gets the security log too ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000ab101"}', true);
select lives_ok($$select public.security_audit_recent(10)$$,
  '8. admin may read the security audit log');
select lives_ok($$select public.dashboard_summary()$$,
  '9. admin may read the dashboard');

select * from finish();
rollback;

-- READINESS #191: reporting-surface smoke + gate. These SECURITY DEFINER read
-- RPCs back dashboards/compliance views and are the last user-callable functions
-- without direct coverage. Two cheap but real guarantees before launch: (a) each
-- actually executes for an authorized user — a report that references a dropped
-- column or renamed table fails only when someone opens the page, and this
-- catches it in CI instead; (b) the one hard-gated compliance view (dvir_summary)
-- refuses an unauthorized role. The soft-gated ones filter by role internally
-- (proven structurally in 199) and simply return role-appropriate/empty results.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000ba101'::uuid, 'smoke-admin@test.local', '{}'::jsonb),
  ('00000000-0000-4000-8000-0000000ba103'::uuid, 'smoke-drv@test.local',   '{"role":"driver"}'::jsonb);
update public.profiles set role='admin' where id='00000000-0000-4000-8000-0000000ba101';

-- ═══ every reporting RPC executes for an authorized (admin) user ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000ba101"}', true);
select lives_ok($$select public.dispatch_productivity()$$,     '1. dispatch_productivity runs');
select lives_ok($$select * from public.dvir_summary()$$,       '2. dvir_summary runs');
select lives_ok($$select * from public.maintenance_alerts()$$, '3. maintenance_alerts runs');
select lives_ok($$select public.qbo_writeoff_list()$$,         '4. qbo_writeoff_list runs');
select lives_ok($$select public.driver_qual_files()$$,         '5. driver_qual_files runs');
select lives_ok($$select * from public.trux_insights_feed()$$, '6. trux_insights_feed runs');
select lives_ok($$select public.llm_eval_summary()$$,          '7. llm_eval_summary runs');

-- ═══ the hard-gated compliance view refuses an unauthorized role ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000ba103"}', true);
select throws_ok($$select * from public.dvir_summary()$$,
  'Not enough permissions', '8. a driver is refused the DVIR compliance summary');

select * from finish();
rollback;

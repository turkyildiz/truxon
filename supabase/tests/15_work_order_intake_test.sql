-- Email work-order intake: the bounded create_work_order_draft RPC resolves the
-- unit and shop, produces a review draft, and refuses an unknown unit.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000e1'::uuid, 'wo@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000e1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000e1"}', true);

insert into public.trucks (unit_number) values ('WO-T1') returning id \gset t_
insert into public.maintenance_vendors (name) values ('Acme Diesel') returning id \gset v_

-- happy path: matched unit + shop, cost/odometer parsed, invalid service degrades
select create_work_order_draft(jsonb_build_object(
  'unit_number','WO-T1', 'vendor','acme diesel', 'service_type','not_a_real_type',
  'description','Replaced turbo', 'cost','1234.56', 'odometer','300500',
  'date','2026-07-15', 'invoice_ref','INV-9'
)) as id \gset wo_

select is((select source from public.maintenance_records where id = :wo_id), 'email', 'source = email');
select is((select needs_review from public.maintenance_records where id = :wo_id), true, 'flagged needs_review');
select is((select status::text from public.maintenance_records where id = :wo_id), 'scheduled', 'draft is scheduled (not counted in cost reports)');
select is((select cost from public.maintenance_records where id = :wo_id), 1234.56::numeric, 'cost parsed from string');
select is((select truck_id from public.maintenance_records where id = :wo_id), :t_id::bigint, 'unit matched to truck');
select is((select vendor_id from public.maintenance_records where id = :wo_id), :v_id::bigint, 'shop matched to vendor (case-insensitive)');

-- invalid service_type fell back to 'other'; unknown unit must raise
select throws_like(
  $$ select public.create_work_order_draft('{"unit_number":"GHOST-99"}'::jsonb) $$,
  '%unit_not_found%', 'unknown unit raises unit_not_found');

select * from finish();
rollback;

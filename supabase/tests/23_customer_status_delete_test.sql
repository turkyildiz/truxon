-- Customer lifecycle: do_not_use flag + the guarded delete (only when we've
-- never hauled their cargo — no loads and no invoices) + admin gate.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

-- seed a real admin caller (auth.users insert creates the profile via trigger;
-- activity_log.user_id FKs to auth.users, so the actor must exist)
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000e23'::uuid, 'del@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000e23';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000e23"}', true);

-- do_not_use defaults false
insert into public.customers (company_name) values ('DoNu Test Broker');
select is((select do_not_use from public.customers where company_name = 'DoNu Test Broker'), false, 'do_not_use defaults false');

-- deletable: no loads, no invoices
insert into public.customers (company_name) values ('Never Hauled Broker');
select lives_ok(
  $$select public.delete_customer((select id from public.customers where company_name = 'Never Hauled Broker'))$$,
  'delete allowed when we never hauled their cargo');
select is((select count(*)::int from public.customers where company_name = 'Never Hauled Broker'), 0, 'customer removed');

-- blocked: has a load
insert into public.customers (company_name) values ('Hauled Broker');
insert into public.loads (load_number, customer_id) select 'DEL-L1', id from public.customers where company_name = 'Hauled Broker';
select throws_like(
  $$select public.delete_customer((select id from public.customers where company_name = 'Hauled Broker'))$$,
  '%have hauled their cargo%', 'delete blocked when loads exist');
select is((select count(*)::int from public.customers where company_name = 'Hauled Broker'), 1, 'customer with loads survives');

-- blocked: has an invoice
insert into public.customers (company_name) values ('Invoiced Broker');
insert into public.invoices (invoice_number, customer_id) select 'DEL-INV-1', id from public.customers where company_name = 'Invoiced Broker';
select throws_like(
  $$select public.delete_customer((select id from public.customers where company_name = 'Invoiced Broker'))$$,
  '%have hauled their cargo%', 'delete blocked when invoices exist');

-- non-admin cannot delete
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000e23';
select throws_like(
  $$select public.delete_customer((select id from public.customers where company_name = 'DoNu Test Broker'))$$,
  '%Not enough permissions%', 'non-admin cannot delete');

select * from finish();
rollback;

-- Check-call log: dispatcher can log, driver cannot, empty notes rejected.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000150'::uuid, 'cc@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000150';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000150"}', true);

insert into public.customers (company_name) values ('CC Broker');
insert into public.loads (customer_id, rate, miles) values
  ((select id from public.customers where company_name='CC Broker'), 1000, 400);

insert into public.load_checkcalls (load_id, note)
values ((select max(id) from public.loads), '0930 driver loaded, 4 pallets short — broker notified');
select is((select count(*)::int from public.load_checkcalls), 1, 'check-call logged');
select throws_ok(
  $$insert into public.load_checkcalls (load_id, note) values ((select max(id) from public.loads), '  ')$$,
  '23514', null, 'blank note rejected');

select * from finish();
rollback;

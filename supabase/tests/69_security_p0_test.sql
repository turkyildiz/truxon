-- Security P0: inactive lockout, last-admin guard, void reopens accessorials,
-- re-bill keeps detention, proposals refresh, pay-profile gate.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f68'::uuid, 'sec-admin@test.local'),
  ('00000000-0000-4000-8000-000000000f69'::uuid, 'sec-driver@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f68';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f69';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f68"}', true);

-- S-06: deactivated account fails closed everywhere my_role() is consulted
update public.profiles set is_active = false where id = '00000000-0000-4000-8000-000000000f69';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f69"}', true);
select throws_ok('select public.my_role()', 'P0001', 'Account disabled',
  'inactive account raises instead of returning a role');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f68"}', true);

-- S-07: driver role cannot read pay analytics
update public.profiles set is_active = true where id = '00000000-0000-4000-8000-000000000f69';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f69"}', true);
select throws_ok('select * from public.customer_pay_profile()', 'P0001', 'Not enough permissions',
  'customer_pay_profile gated away from drivers');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f68"}', true);

-- S-12: last active admin is protected at the DB level
select throws_ok(
  $$update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000f68'$$,
  'P0001', 'Cannot demote or deactivate the last active admin',
  'last-admin demotion blocked by trigger');

-- B-01/B-02: approve detention → invoice → void → re-invoice keeps the money
insert into public.customers (company_name) values ('Void Broker');
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time)
values ('SEC-1', (select id from public.customers where company_name = 'Void Broker'),
        'completed', 2000, 700, now() - interval '3 days');
insert into public.load_accessorials (load_id, atype, stop_type, amount, minutes, detail)
values ((select id from public.loads where load_number = 'SEC-1'),
        'detention', 'delivery', 150, 180, 'seeded');
update public.load_accessorials set status = 'approved'
 where load_id = (select id from public.loads where load_number = 'SEC-1');

select is(
  (select (public.create_invoice(
     (select customer_id from public.loads where load_number = 'SEC-1'),
     array[(select id from public.loads where load_number = 'SEC-1')],
     now() + interval '30 days')).total),
  2150::numeric, 'invoice total folds the approved detention in');
select is(
  (select status from public.load_accessorials
    where load_id = (select id from public.loads where load_number = 'SEC-1')),
  'invoiced', 'accessorial marked invoiced with the invoice');

select public.void_invoice((select invoice_id from public.loads where load_number = 'SEC-1'));
select is(
  (select status from public.load_accessorials
    where load_id = (select id from public.loads where load_number = 'SEC-1')),
  'approved', 'VOID reopens the accessorial (B-01)');

select is(
  (select (public.create_invoice(
     (select customer_id from public.loads where load_number = 'SEC-1'),
     array[(select id from public.loads where load_number = 'SEC-1')],
     now() + interval '30 days')).total),
  2150::numeric, 're-bill after void still includes the detention money');

select * from finish();
rollback;

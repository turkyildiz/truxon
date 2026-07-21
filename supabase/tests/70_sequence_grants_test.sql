-- GT-09: sequence-burn hygiene — invoice numbering is definer-only, load
-- numbering is office-gated but still flows through the insert trigger.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f70'::uuid, 'seq-admin@test.local'),
  ('00000000-0000-4000-8000-000000000f71'::uuid, 'seq-driver@test.local');
update public.profiles set role = 'admin'  where id = '00000000-0000-4000-8000-000000000f70';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f71';

select is(has_function_privilege('authenticated', 'public.next_invoice_number()', 'execute'),
  false, 'authenticated cannot execute next_invoice_number (definer-only)');
select is(has_function_privilege('anon', 'public.next_invoice_number()', 'execute'),
  false, 'anon cannot execute next_invoice_number');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f71"}', true);
select throws_ok('select public.next_load_number()', 'P0001', 'Not enough permissions',
  'driver cannot burn load numbers via direct RPC');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f70"}', true);
select matches(public.next_load_number(), '^LD-\d{4}-\d{4}$',
  'office role still draws load numbers');

insert into public.customers (company_name) values ('Seq Broker');
insert into public.loads (customer_id, status, rate, miles)
values ((select id from public.customers where company_name = 'Seq Broker'), 'pending', 1000, 400);
select matches(
  (select load_number from public.loads
    where customer_id = (select id from public.customers where company_name = 'Seq Broker')),
  '^LD-\d{4}-\d{4}$', 'insert trigger still assigns a load number');

select * from finish();
rollback;

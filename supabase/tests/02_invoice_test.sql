-- Invoice money path: totals, sequence numbering (no reuse after void),
-- soft-void semantics, billed-load locking, and the guards around
-- set_invoice_status and deletion.
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

-- ---------- seed ----------
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f02'::uuid, 'inv-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f02';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f02"}', true);

insert into public.customers (company_name) values ('INV Test Broker'), ('INV Other Broker');
insert into public.drivers (full_name, pay_per_mile) values ('INV Test Driver', 0.55);
insert into public.trucks (unit_number) values ('INV-T1');

-- Three loads for the main broker, one for the other. The app.load_rpc flag
-- lets the seed place them directly into 'completed' (and is reset after).
insert into public.loads (customer_id, rate, miles, notes)
  select id, 500.25, 100, 'inv-a' from public.customers where company_name = 'INV Test Broker';
insert into public.loads (customer_id, rate, miles, notes)
  select id, 700.25, 200, 'inv-b' from public.customers where company_name = 'INV Test Broker';
insert into public.loads (customer_id, rate, miles, notes)
  select id, 300.00, 80, 'inv-c' from public.customers where company_name = 'INV Test Broker';
insert into public.loads (customer_id, rate, miles, notes)
  select id, 100.00, 10, 'inv-other' from public.customers where company_name = 'INV Other Broker';

select set_config('app.load_rpc', '1', true);
update public.loads
   set status = 'completed',
       driver_id = (select id from public.drivers where full_name = 'INV Test Driver'),
       truck_id  = (select id from public.trucks where unit_number = 'INV-T1')
 where notes in ('inv-a', 'inv-b', 'inv-other');
select set_config('app.load_rpc', '', true);

-- ---------- create ----------
select is(
  (select (public.create_invoice(
      (select id from public.customers where company_name = 'INV Test Broker'),
      array[(select id from public.loads where notes = 'inv-a'),
            (select id from public.loads where notes = 'inv-b')])).total),
  1200.50::numeric(12,2),
  'invoice total is the sum of its load rates'
);

select matches(
  (select invoice_number from public.invoices
    where customer_id = (select id from public.customers where company_name = 'INV Test Broker')),
  '^INV-\d{4}-\d{4}$',
  'invoice number follows INV-YYYY-NNNN'
);

select is(
  (select count(*) from public.loads where notes in ('inv-a','inv-b') and status = 'billed'
      and invoice_id is not null),
  2::bigint,
  'invoiced loads are billed and linked'
);

select throws_ok(
  $$update public.loads set rate = 999 where notes = 'inv-a'$$,
  'Billed loads are locked; void the invoice first',
  'billed loads are locked'
);

-- ---------- guards ----------
select throws_like(
  $$select public.create_invoice(
      (select id from public.customers where company_name = 'INV Test Broker'),
      array[(select id from public.loads where notes = 'inv-c')])$$,
  '%is not completed',
  'only completed loads can be invoiced'
);

select throws_like(
  $$select public.create_invoice(
      (select id from public.customers where company_name = 'INV Test Broker'),
      array[(select id from public.loads where notes = 'inv-other')])$$,
  '%belongs to a different customer',
  'cross-customer invoicing is rejected'
);

-- A billed load is no longer 'completed', so re-invoicing trips the status
-- guard (which fires before the already-invoiced check ever could).
select throws_like(
  $$select public.create_invoice(
      (select id from public.customers where company_name = 'INV Test Broker'),
      array[(select id from public.loads where notes = 'inv-a')])$$,
  '%is not completed',
  'billed loads cannot be invoiced twice'
);

-- ---------- numbering across void ----------
select set_config('app.load_rpc', '1', true);
update public.loads set status = 'completed' where notes = 'inv-c';
select set_config('app.load_rpc', '', true);

select ok(
  (select (public.create_invoice(
      (select id from public.customers where company_name = 'INV Test Broker'),
      array[(select id from public.loads where notes = 'inv-c')])).invoice_number
   > (select min(invoice_number) from public.invoices
       where customer_id = (select id from public.customers where company_name = 'INV Test Broker'))),
  'invoice numbers strictly increase'
);

select lives_ok(
  $$select public.void_invoice((select min(id) from public.invoices
      where customer_id = (select id from public.customers where company_name = 'INV Test Broker')))$$,
  'voiding an unpaid invoice works'
);

select is(
  (select status::text from public.invoices
    where id = (select min(id) from public.invoices
      where customer_id = (select id from public.customers where company_name = 'INV Test Broker'))),
  'void',
  'voided invoice stays on record as void'
);

select is(
  (select count(*) from public.loads where notes in ('inv-a','inv-b')
      and status = 'completed' and invoice_id is null),
  2::bigint,
  'voiding reverts its loads to completed'
);

-- A fresh invoice after the void must get a NEW number.
select ok(
  (select (public.create_invoice(
      (select id from public.customers where company_name = 'INV Test Broker'),
      array[(select id from public.loads where notes = 'inv-a')])).invoice_number
   <> all (select invoice_number from public.invoices
            where customer_id = (select id from public.customers where company_name = 'INV Test Broker')
              and status = 'void')),
  'voided invoice numbers are never reused'
);

-- ---------- immutability ----------
select throws_ok(
  $$delete from public.invoices where id = (select min(id) from public.invoices)$$,
  'Invoices are never deleted — use void_invoice() instead',
  'invoices cannot be hard-deleted'
);

select throws_ok(
  $$select public.set_invoice_status((select max(id) from public.invoices), 'void')$$,
  'Use void_invoice() — voiding also reverts the invoice''s loads',
  'set_invoice_status cannot void'
);

select throws_ok(
  $$select public.set_invoice_status(
      (select min(id) from public.invoices
        where customer_id = (select id from public.customers where company_name = 'INV Test Broker')),
      'sent')$$,
  'Voided invoices are immutable',
  'voided invoices cannot be revived'
);

select * from finish();
rollback;

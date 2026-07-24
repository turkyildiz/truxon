-- READINESS #177: end-to-end money path as ONE lifecycle. Every stage is
-- unit-tested elsewhere; this proves the whole chain ties together —
-- create → assign → roll → deliver → complete → invoice → pay → paid+billed —
-- through the real RPCs and their triggers/guards, the way a dollar actually
-- travels through the system.
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000001a7'::uuid, 'e2e-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000001a7';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000001a7"}', true);

insert into public.customers (company_name, payment_terms) values ('E2E Broker', 'Net 30');
insert into public.drivers (full_name, status) values ('E2E Driver', 'active');
insert into public.trucks (unit_number, status) values ('E2E-T', 'available');

-- ── 1. CREATE: a booked load gets a real load number from the trigger ──
insert into public.loads (customer_id, driver_id, truck_id, rate, miles, status, pickup_time, delivery_time)
select c.id, d.id, t.id, 2400, 600, 'pending', now() - interval '2 days', now() - interval '1 day'
  from public.customers c, public.drivers d, public.trucks t
 where c.company_name='E2E Broker' and d.full_name='E2E Driver' and t.unit_number='E2E-T';
select ok((select load_number is not null and load_number <> '' from public.loads where notes = '' and rate = 2400),
  '1. create: the load got a real load number');

-- capture the id
create temp table L as select id from public.loads where rate = 2400 limit 1;

-- ── 2-5. ADVANCE through the workflow via the guarded RPC ──
select public.change_load_status((select id from L), 'assigned');
select is((select status from public.loads where id = (select id from L)), 'assigned', '2. assigned (driver+truck present)');
select public.change_load_status((select id from L), 'in_transit');
select is((select status from public.loads where id = (select id from L)), 'in_transit', '3. rolling');
select public.change_load_status((select id from L), 'delivered');
select is((select status from public.loads where id = (select id from L)), 'delivered', '4. delivered');
select public.change_load_status((select id from L), 'completed');
select is((select status from public.loads where id = (select id from L)), 'completed', '5. completed (billable)');

-- ── 6. INVOICE: create_invoice bundles the completed load, sets invoice_id ──
select public.create_invoice((select id from public.customers where company_name='E2E Broker'),
                             array[(select id from L)]);
select is((select invoice_id is not null from public.loads where id = (select id from L)), true,
  '6. invoice: the load is now linked to an invoice');
select is((select total from public.invoices i join L on true where i.id = (select invoice_id from public.loads where id = (select id from L))),
  2400.00, '6b. invoice total equals the load rate');

-- send it
create temp table I as select invoice_id as id from public.loads where id = (select id from L);
select public.set_invoice_status((select id from I), 'sent');
select is((select status from public.invoices where id = (select id from I)), 'sent', '7. invoice sent');

-- ── 8. PAY: record the payment, which auto-flips to paid at zero balance ──
select public.record_invoice_payment((select id from I), 2400.00, 'check', 'CHK-1001');
select is((select status from public.invoices where id = (select id from I)), 'paid',
  '8. full payment auto-flips the invoice to paid');
select is((select public.invoice_balance(i) from public.invoices i where i.id = (select id from I)), 0.00,
  '9. balance is zero — the dollar completed its journey');

select * from finish();
rollback;

-- Factoring: a factored invoice's balance is the FACTOR's debt, not the
-- broker's. It must leave every customer-A/R surface (summary, aging,
-- collections, slow-pay, credit exposure) and appear in the Factoring view;
-- un-factoring puts it back. Guards the 20260721234001 MVP + 236001 sweep.
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f89'::uuid, 'fact@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f89';
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000f89","role":"authenticated"}', true);

insert into public.customers (company_name) values ('FACTOR TEST BROKER');

-- an overdue sent invoice with a 90% partial payment (the factoring advance)
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source)
select 'FT89-1', id, now() - interval '40 days', now() - interval '10 days', 1000, 'sent', 'truxon'
  from public.customers where company_name = 'FACTOR TEST BROKER';
insert into public.invoice_payments (invoice_id, amount, method, received_at)
select id, 900, 'factoring', now() - interval '38 days'
  from public.invoices where invoice_number = 'FT89-1';

-- BEFORE factoring: it IS broker A/R everywhere
select ok((public.acct_summary()->>'ar_total')::numeric >= 100,
  'before: the $100 balance counts in ar_total');
select ok(exists(select 1 from public.ar_aging() a
                  join public.customers c on c.id = a.customer_id
                 where c.company_name = 'FACTOR TEST BROKER'),
  'before: broker appears in ar_aging');
select ok(exists(select 1 from public.collections_queue() q
                  where q.company_name = 'FACTOR TEST BROKER'),
  'before: broker appears in the collections queue');

-- factor it
select public.mark_invoice_factored((select id from public.invoices where invoice_number='FT89-1'), 'Denim', 25);
select ok((select factored_at is not null from public.invoices where invoice_number='FT89-1'),
  'mark_invoice_factored stamps factored_at');

-- AFTER: gone from every broker-A/R surface
select ok(not exists(select 1 from public.ar_aging() a
                      join public.customers c on c.id = a.customer_id
                     where c.company_name = 'FACTOR TEST BROKER'),
  'after: broker leaves ar_aging');
select ok(not exists(select 1 from public.collections_queue() q
                      where q.company_name = 'FACTOR TEST BROKER'),
  'after: broker leaves the collections queue');
select ok(not exists(select 1 from public.slow_pay_risk() r
                      join public.invoices i on i.id = r.invoice_id
                     where i.invoice_number = 'FT89-1'),
  'after: factored invoice not flagged as slow-pay');
select is(
  (select (public.customer_exposure(c.id)->>'open_ar')::numeric
     from public.customers c where c.company_name = 'FACTOR TEST BROKER'),
  0::numeric, 'after: reserve does not count against the broker credit limit');

-- ...and lands in the Factoring view with the right reserve
select ok(exists(
    select 1 from jsonb_array_elements(public.factoring_overview()->'invoices') r
     where r->>'invoice_number' = 'FT89-1'
       and (r->>'reserve_pending')::numeric = 100
       and (r->>'fee')::numeric = 25),
  'factoring_overview shows the invoice with $100 reserve and $25 fee');

-- un-factor puts it back
select public.unmark_invoice_factored((select id from public.invoices where invoice_number='FT89-1'));
select ok(exists(select 1 from public.collections_queue() q
                  where q.company_name = 'FACTOR TEST BROKER'),
  'unmark returns the broker to the collections queue');

select * from finish();
rollback;

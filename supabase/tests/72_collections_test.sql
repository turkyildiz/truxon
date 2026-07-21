-- R3 #1: collections queue math, promise ledger RLS, dunning draft idempotency.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f75'::uuid, 'col-admin@test.local'),
  ('00000000-0000-4000-8000-000000000f76'::uuid, 'col-driver@test.local');
update public.profiles set role = 'admin'  where id = '00000000-0000-4000-8000-000000000f75';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f76';

insert into public.customers (company_name, contact_person, email)
values ('Slow Broker Inc', 'Pat', 'ap@slowbroker.test');

-- two overdue sent invoices: $2,000 due 40 days ago, $1,000 due 10 days ago
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status)
select 'COL-' || n, id, now() - interval '70 days',
       now() - (case n when 1 then interval '40 days' else interval '10 days' end),
       case n when 1 then 2000 else 1000 end, 'sent'
from public.customers, generate_series(1, 2) n
where company_name = 'Slow Broker Inc';

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f75"}', true);

select is((select q.overdue_total from public.collections_queue() q
            where q.company_name = 'Slow Broker Inc'), 3000::numeric,
  'queue sums both overdue balances');
select is((select q.oldest_days from public.collections_queue() q
            where q.company_name = 'Slow Broker Inc'), 40,
  'oldest_days tracks the stalest invoice');
select is((select jsonb_array_length(q.invoices) from public.collections_queue() q
            where q.company_name = 'Slow Broker Inc'), 2,
  'per-invoice detail rides along');
select is((select q.priority from public.collections_queue() q
            where q.company_name = 'Slow Broker Inc'),
  round(3000 * (1 + 40/30.0), 2), 'priority = dollars x age pressure');

-- promise ledger: admin writes, queue surfaces the latest promise
insert into public.collection_notes (customer_id, note, promised_amount, promised_date)
select id, 'Pat promises wire Friday', 3000, current_date + 4
  from public.customers where company_name = 'Slow Broker Inc';
select is((select (q.last_promise->>'promised_amount')::numeric from public.collections_queue() q
            where q.company_name = 'Slow Broker Inc'), 3000::numeric,
  'latest promise surfaces in the queue');

-- driver: no queue, no ledger
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f76"}', true);
select throws_ok('select * from public.collections_queue()', 'P0001', 'Not enough permissions',
  'queue is office-only');
-- RLS is bypassed for the table owner, so drop into the authenticated role
-- (grant supplied in-transaction; local resets lack prod's default grants).
grant select, insert on public.collection_notes to authenticated;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f76","role":"authenticated"}', true);
select throws_ok(
  $$insert into public.collection_notes (customer_id, note)
    select id, 'driver note' from public.customers where company_name = 'Slow Broker Inc'$$,
  '42501', null, 'drivers cannot write collection notes');
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f75"}', true);

-- dunning drafts: one per customer per week, idempotent
select cmp_ok(public.draft_dunning_notices(), '>=', 1, 'dunning draft created');
select is(public.draft_dunning_notices(), 0, 'second run same week drafts nothing new');

select * from finish();
rollback;

-- Fee write-off proposals: seed finds slivers, decisions stick, and nothing
-- ever touches the invoice itself (propose-only by construction).
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000126'::uuid, 'wo@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000126';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000126"}', true);

insert into public.customers (company_name) values ('WO Broker');
-- a live fee sliver and a cleared one
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, qbo_balance, factored_at, factoring_fee, factor_name)
values ('WO-SLIVER', (select id from public.customers where company_name='WO Broker'),
        current_date - 50, current_date - 20, 1200, 'sent', 'qbo', 60, now(), 60, 'Denim'),
       ('WO-CLEARED', (select id from public.customers where company_name='WO Broker'),
        current_date - 50, current_date - 20, 1200, 'sent', 'qbo', 0, now(), 60, 'Denim');

select ok(public.qbo_writeoff_seed() >= 1, 'seed proposes the live sliver');
select ok(not exists (select 1 from public.qbo_writeoff_proposals p
    join public.invoices i on i.id = p.invoice_id where i.invoice_number = 'WO-CLEARED'),
  'a cleared sliver is not proposed');
select is(public.qbo_writeoff_seed(), 0, 'seed is idempotent');

select public.qbo_writeoff_decide(
  (select p.id from public.qbo_writeoff_proposals p
    join public.invoices i on i.id = p.invoice_id where i.invoice_number = 'WO-SLIVER'), true);
select is(
  (select p.status from public.qbo_writeoff_proposals p
    join public.invoices i on i.id = p.invoice_id where i.invoice_number = 'WO-SLIVER'),
  'approved', 'approval sticks');
select is(
  (select qbo_balance from public.invoices where invoice_number = 'WO-SLIVER'),
  60::numeric, 'approval NEVER touches the invoice — books stay untouched');

select * from finish();
rollback;

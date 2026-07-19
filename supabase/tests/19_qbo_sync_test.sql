-- QBO sync mirror: upsert creates/matches customers, maps paid/void from the
-- books, stays idempotent, and never lets a browser role near the RPCs.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

-- an existing customer that should be MATCHED by name (not duplicated)
insert into public.customers (company_name) values ('TQL');

-- service context: no user (post-rotation convention for service calls)
select set_config('request.jwt.claims', '', true);

-- first pull: one invoice for a known customer, one for a brand-new broker
select is(
  public.qbo_upsert_invoices(jsonb_build_array(
    jsonb_build_object('qbo_id','9188','doc_number','4521','customer_qbo_id','36','customer_name','TQL',
                       'txn_date','2026-07-19','due_date','2026-08-18','total',6000,'balance',6000,'voided',false),
    jsonb_build_object('qbo_id','9187','doc_number','4520','customer_qbo_id','234','customer_name','HIGH TIDE LOGISTICS LLC',
                       'txn_date','2026-07-19','due_date','2026-08-18','total',2450,'balance',2450,'voided',false)
  ))->>'inserted', '2', 'two invoices inserted');

select is((select qbo_id from public.customers where company_name='TQL'), '36', 'existing customer matched by name and tagged');
select is((select count(*)::int from public.customers where company_name='HIGH TIDE LOGISTICS LLC'), 1, 'new broker auto-created');
select is((select status::text from public.invoices where qbo_id='9188'), 'sent', 'open invoice mirrors as sent');
select is((select invoice_number from public.invoices where qbo_id='9188'), 'QBO-4521', 'mirror numbering carries the QBO doc number');

-- re-pull with a payment landed: balance 0 flips it to paid (idempotent update)
select is(
  public.qbo_upsert_invoices(jsonb_build_array(
    jsonb_build_object('qbo_id','9188','doc_number','4521','customer_qbo_id','36','customer_name','TQL',
                       'txn_date','2026-07-19','due_date','2026-08-18','total',6000,'balance',0,'voided',false)
  ))->>'updated', '1', 're-pull updates, never duplicates');
select is((select status::text from public.invoices where qbo_id='9188'), 'paid', 'zero balance from the books = paid');
select is((select count(*)::int from public.invoices where qbo_id='9188'), 1, 'still exactly one row');

-- CDC-deleted invoice → void
select is(public.qbo_mark_voided('["9187"]'::jsonb), 1, 'deleted-in-QBO marks the mirror void');
select is((select status::text from public.invoices where qbo_id='9187'), 'void', 'void state landed');

-- a signed-in browser user (even admin) must NOT be able to call the service RPC
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000b01'::uuid, 'qbo@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000b01';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000b01"}', true);
select throws_ok(
  $$select public.qbo_upsert_invoices('[]'::jsonb)$$,
  'Not enough permissions',
  'browser sessions cannot invoke the sync RPC');

select * from finish();
rollback;

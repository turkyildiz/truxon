-- Customer dedup: name normalization, duplicate grouping, merge mechanics
-- (repointing, blanks-fill, qbo transfer + alias), and the alias fallback that
-- stops the QBO invoice pull from resurrecting a merged duplicate.
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

-- ── normalization ──
select is(public.normalize_company_name('AM Trans Expedite, L.L.C.'),
          public.normalize_company_name('am trans expedite llc'), 'punctuation + suffix insensitive');
select is(public.normalize_company_name('COYOTE LOGISTICS CO., INC.'), 'coyote logistics', 'stacked suffixes stripped');
select is(public.normalize_company_name('  Echo   Global  '), 'echo global', 'whitespace collapsed');

-- ── fixture: a real customer with history + a QBO-created dupe ──
insert into public.customers (company_name, phone, qbo_id) values ('Coyote Logistics LLC', '555-0100', null);
insert into public.customers (company_name, email, qbo_id) values ('COYOTE LOGISTICS, LLC.', 'ap@coyote.com', 'QBO-77');
insert into public.drivers (full_name) values ('Merge Test Driver');
insert into public.loads (load_number, customer_id, pickup_address, delivery_address, rate)
  select 'MRG-1', id, 'a', 'b', 100 from public.customers where company_name = 'Coyote Logistics LLC';
insert into public.loads (load_number, customer_id, pickup_address, delivery_address, rate)
  select 'MRG-2', id, 'a', 'b', 100 from public.customers where company_name = 'COYOTE LOGISTICS, LLC.';
insert into public.invoices (invoice_number, customer_id, total, status)
  select 'INV-MRG-1', id, 100, 'draft' from public.customers where company_name = 'COYOTE LOGISTICS, LLC.';
insert into public.documents (entity_type, entity_id, filename, storage_path, content_type)
  select 'customer', id, 'setup.pdf', 'customer/mrg.pdf', 'application/pdf'
  from public.customers where company_name = 'COYOTE LOGISTICS, LLC.';

-- ── grouping finds them ──
select set_config('request.jwt.claims', '', true);
select is(
  (select count(*)::int from public.duplicate_customer_groups() g
    where g.norm_key = 'coyote logistics'), 1, 'dupe group detected');

-- ── merge ──
do $$
declare k bigint; d bigint;
begin
  select id into k from public.customers where company_name = 'Coyote Logistics LLC';
  select id into d from public.customers where company_name = 'COYOTE LOGISTICS, LLC.';
  perform public.merge_customers(k, d);
end $$;

select is((select count(*)::int from public.customers where company_name ilike 'coyote%'), 1, 'dupe row deleted');
select is((select count(*)::int from public.loads where load_number in ('MRG-1','MRG-2')
           and customer_id = (select id from public.customers where company_name = 'Coyote Logistics LLC')), 2, 'loads repointed');
select is((select count(*)::int from public.invoices where invoice_number = 'INV-MRG-1'
           and customer_id = (select id from public.customers where company_name = 'Coyote Logistics LLC')), 1, 'invoices repointed');
select is((select count(*)::int from public.documents where filename = 'setup.pdf'
           and entity_id = (select id from public.customers where company_name = 'Coyote Logistics LLC')), 1, 'documents repointed');
select is((select email from public.customers where company_name = 'Coyote Logistics LLC'), 'ap@coyote.com', 'blank email filled from dupe');
select is((select phone from public.customers where company_name = 'Coyote Logistics LLC'), '555-0100', 'existing phone untouched');
select is((select qbo_id from public.customers where company_name = 'Coyote Logistics LLC'), 'QBO-77', 'qbo_id transferred to keeper');

-- ── alias path: keeper already has a qbo_id → dupe id goes to the ledger,
--    and the invoice pull maps it back instead of re-creating the customer ──
insert into public.customers (company_name, qbo_id) values ('Coyote Logistics (dupe 2)', 'QBO-88');
do $$
declare k bigint; d bigint;
begin
  select id into k from public.customers where company_name = 'Coyote Logistics LLC';
  select id into d from public.customers where company_name = 'Coyote Logistics (dupe 2)';
  perform public.merge_customers(k, d);
end $$;
select is((select customer_id from public.customer_qbo_aliases where qbo_id = 'QBO-88'),
          (select id from public.customers where company_name = 'Coyote Logistics LLC'), 'second qbo_id recorded as alias');

select public.qbo_upsert_invoices(jsonb_build_array(jsonb_build_object(
  'qbo_id', 'QI-500', 'doc_number', '500', 'customer_qbo_id', 'QBO-88',
  'customer_name', 'Coyote Logistics (dupe 2)', 'txn_date', '2026-07-01',
  'due_date', '2026-07-31', 'total', 250, 'balance', 250, 'voided', false)));
select is((select count(*)::int from public.customers where company_name ilike 'coyote%'), 1,
  'invoice pull with merged qbo_id does NOT resurrect the dupe');
select is((select customer_id from public.invoices where qbo_id = 'QI-500'),
          (select id from public.customers where company_name = 'Coyote Logistics LLC'), 'aliased invoice lands on the keeper');

-- ── billed loads: merge may repoint them (customer_id only); direct edits stay locked ──
insert into public.customers (company_name) values ('Billed Dupe LLC');
insert into public.loads (load_number, customer_id, pickup_address, delivery_address, rate, status)
  select 'MRG-BILLED', id, 'a', 'b', 500, 'billed' from public.customers where company_name = 'Billed Dupe LLC';
do $$
declare k bigint; d bigint;
begin
  select id into k from public.customers where company_name = 'Coyote Logistics LLC';
  select id into d from public.customers where company_name = 'Billed Dupe LLC';
  perform public.merge_customers(k, d);
end $$;
select is((select customer_id from public.loads where load_number = 'MRG-BILLED'),
          (select id from public.customers where company_name = 'Coyote Logistics LLC'),
          'merge repoints a billed load');
select throws_like($$ update public.loads set rate = 1 where load_number = 'MRG-BILLED' $$,
  '%Billed loads are locked%', 'billed load stays locked outside merge');

-- ── usdot joins the enrichment allow-list ──
select is(public.apply_customer_enrichment(
  (select id from public.customers where company_name = 'Coyote Logistics LLC'),
  '{"usdot_number": "1234567"}'::jsonb, null, 'test'), 1, 'usdot_number fills via enrichment');

-- ── gate: a driver cannot merge ──
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000e27'::uuid, 'merge@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000e27';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000e27"}', true);
select throws_like($$ select public.merge_customers(1, 2) $$, '%Not enough permissions%', 'driver cannot merge');

select * from finish();
rollback;

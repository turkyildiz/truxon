-- AI memory: correction capture (human overwrites AI value → ground truth;
-- service writes and non-AI edits are not corrections) and few-shot example
-- retrieval over indexed documents.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000e28'::uuid, 'mem@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000e28';

insert into public.customers (company_name) values ('Memory Broker LLC');

-- ── AI writes a phone (service context) ──
select set_config('request.jwt.claims', '', true);
select is(public.apply_customer_enrichment(
  (select id from public.customers where company_name = 'Memory Broker LLC'),
  '{"phone": "555-0100"}'::jsonb, null, 'test-model'), 1, 'AI fills phone');

-- ── human corrects it → captured ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000e28"}', true);
update public.customers set phone = '555-0199' where company_name = 'Memory Broker LLC';
select is((select count(*)::int from public.ai_corrections
  where field = 'phone' and model_value = '555-0100' and human_value = '555-0199'
    and model = 'test-model'), 1, 'human overwrite of AI value captured as correction');

-- ── human edits a field the AI never wrote → NOT a correction ──
update public.customers set email = 'ap@memory.test' where company_name = 'Memory Broker LLC';
select is((select count(*)::int from public.ai_corrections where field = 'email'), 0,
  'edit of non-AI field is not a correction');

-- ── service overwrite is never a correction ──
select set_config('request.jwt.claims', '', true);
update public.customers set phone = '555-0777' where company_name = 'Memory Broker LLC';
select is((select count(*)::int from public.ai_corrections where field = 'phone'), 1,
  'service write does not add corrections');

-- ── example retrieval: doc A (query) finds doc B (has enrichment history) ──
insert into public.documents (entity_type, entity_id, filename, storage_path, content_type)
  select 'customer', id, 'query.pdf', 'c/q.pdf', 'application/pdf' from public.customers where company_name = 'Memory Broker LLC';
insert into public.documents (entity_type, entity_id, filename, storage_path, content_type)
  select 'customer', id, 'example.pdf', 'c/e.pdf', 'application/pdf' from public.customers where company_name = 'Memory Broker LLC';
create temporary table _v as select jsonb_agg(0) as emb from generate_series(1, 768);
select public.upsert_doc_embeddings(
  (select id from public.documents where filename = 'query.pdf'), 'customer',
  (select entity_id from public.documents where filename = 'query.pdf'),
  jsonb_build_array(jsonb_build_object('content', 'rate con text', 'embedding', (select emb from _v))));
select public.upsert_doc_embeddings(
  (select id from public.documents where filename = 'example.pdf'), 'customer',
  (select entity_id from public.documents where filename = 'example.pdf'),
  jsonb_build_array(jsonb_build_object('content', 'other rate con', 'embedding', (select emb from _v))));
-- enrichment history sourced from example.pdf
select public.apply_customer_enrichment(
  (select id from public.customers where company_name = 'Memory Broker LLC'),
  '{"billing_address": "PO Box 9, Chicago, IL"}'::jsonb,
  (select id from public.documents where filename = 'example.pdf'), 'test-model');

select is((select count(*)::int from public.match_extraction_examples(
  (select id from public.documents where filename = 'query.pdf'), 2)), 1,
  'similar verified document returned as example');
select is((select fields->>'billing_address' from public.match_extraction_examples(
  (select id from public.documents where filename = 'query.pdf'), 2) limit 1),
  'PO Box 9, Chicago, IL', 'example carries the verified field map');

-- ── gate: authenticated users cannot call example retrieval ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000e28"}', true);
select throws_like($$ select * from public.match_extraction_examples(1, 2) $$,
  '%Not enough permissions%', 'authenticated caller rejected');

select * from finish();
rollback;

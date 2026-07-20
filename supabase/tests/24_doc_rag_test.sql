-- Document RAG: embedding upsert (replace-by-doc, service gate, indexed_at) and
-- the match RPC's access gate.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

-- a document to attach embeddings to
insert into public.customers (company_name) values ('RAG Test Broker');
insert into public.documents (entity_type, entity_id, filename, storage_path, content_type)
  select 'customer', id, 'ratecon.pdf', 'customer/ratecon.pdf', 'application/pdf'
  from public.customers where company_name = 'RAG Test Broker';

-- a 768-dim zero vector as a JSON array (matches nomic-embed-text dims)
create temporary table _v as select jsonb_agg(0) as emb from generate_series(1, 768);

-- ── service context ──
select set_config('request.jwt.claims', '', true);

select is(
  public.upsert_doc_embeddings(
    (select id from public.documents where filename = 'ratecon.pdf'),
    'customer',
    (select entity_id from public.documents where filename = 'ratecon.pdf'),
    jsonb_build_array(
      jsonb_build_object('content', 'chunk one', 'embedding', (select emb from _v)),
      jsonb_build_object('content', 'chunk two', 'embedding', (select emb from _v))
    )
  ), 2, 'upsert stores two chunks');

select is((select count(*)::int from public.document_embeddings
  where document_id = (select id from public.documents where filename = 'ratecon.pdf')), 2, 'two embedding rows exist');
select isnt((select indexed_at from public.documents where filename = 'ratecon.pdf'), null, 'indexed_at stamped');

-- replace-by-document: re-upsert with one chunk replaces (no dupes)
select is(
  public.upsert_doc_embeddings(
    (select id from public.documents where filename = 'ratecon.pdf'), 'customer',
    (select entity_id from public.documents where filename = 'ratecon.pdf'),
    jsonb_build_array(jsonb_build_object('content', 'only chunk', 'embedding', (select emb from _v)))
  ), 1, 're-upsert replaces');
select is((select count(*)::int from public.document_embeddings
  where document_id = (select id from public.documents where filename = 'ratecon.pdf')), 1, 'no duplicate chunks after re-upsert');

-- ── gate: a non-privileged authenticated user can't search ──
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000e24'::uuid, 'rag@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000e24';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000e24"}', true);
select throws_like(
  $$select public.match_document_embeddings('[' || array_to_string(array(select 0.0 from generate_series(1,768)), ',') || ']', 5, null)$$,
  '%Not enough permissions%', 'driver cannot search documents');

select * from finish();
rollback;

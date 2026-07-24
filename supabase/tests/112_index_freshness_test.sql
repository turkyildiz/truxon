-- R9 #109: index-freshness sentinel — fires when docs wait and the indexer is
-- silent; stays quiet when embeddings are fresh; resolves when indexing resumes.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000b1'::uuid, 'fresh-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000b1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000b1"}', true);

insert into public.customers (company_name) values ('Fresh Broker');
insert into public.loads (customer_id, rate, status, notes)
  select id, 600, 'pending', 'fresh-load' from public.customers where company_name='Fresh Broker';

-- a doc that has waited 4h with a dead indexer (no embeddings anywhere)
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, uploaded_at)
select 'load', id, 'POD', 'waiting.pdf', 'test/waiting', now() - interval '4 hours'
from public.loads where notes='fresh-load';

-- 1. fires: waiting doc + no embeddings ever written
select public.sentinel_scan();
select is(
  (select category||'/'||severity from public.trux_insights where dedup_key='doc_index_stale'),
  'ops/warn', 'stalled indexer fires an ops warn');

-- 2. indexing resumes → resolves on next scan
create temp table _v as select ('['||array_to_string(array_fill(0, array[768]),',')||']')::vector(768) v;
insert into public.document_embeddings (document_id, entity_type, entity_id, chunk_index, content, embedding)
select d.id, 'load', d.entity_id, 0, 'now indexed', (select v from _v)
from public.documents d where d.filename='waiting.pdf';
select public.sentinel_scan();
select is(
  (select status from public.trux_insights where dedup_key='doc_index_stale'),
  'resolved', 'fresh embeddings resolve the stall warning');

-- 3. and it does not re-fire while things are healthy
select public.sentinel_scan();
select is(
  (select status from public.trux_insights where dedup_key='doc_index_stale'),
  'resolved', 'healthy pipeline stays quiet');

select * from finish();
rollback;

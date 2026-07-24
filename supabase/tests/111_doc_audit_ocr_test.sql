-- R9 #102/#103: misfiled-doc sentinel (fires on disagreement, ignores unsure,
-- auto-resolves on relabel) and the OCR-quality verdicts.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000a1'::uuid, 'audit-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000a1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1"}', true);

insert into public.customers (company_name) values ('Audit Broker');
insert into public.loads (customer_id, rate, status, notes)
  select id, 700, 'pending', 'audit-load' from public.customers where company_name='Audit Broker';

-- three docs: misfiled (POD that reads like a rate con), unsure, garbled scan
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path)
select 'load', id, x.t, x.f, 'test/'||x.f
from public.loads l,
     (values ('POD','misfiled.pdf'), ('BOL','unsure.pdf'), ('POD','garbled.pdf')) x(t, f)
where l.notes='audit-load';

-- unit vector, not zero — cosine distance is undefined on zero vectors
create temp table _z as select ('[1,'||array_to_string(array_fill(0, array[767]),',')||']')::vector(768) v;
insert into public.document_embeddings (document_id, entity_type, entity_id, chunk_index, content, embedding)
select d.id, 'load', d.entity_id, 0,
       case d.filename
         when 'garbled.pdf' then repeat('#@%~|', 100)                       -- 500 chars, ~0% word chars
         else repeat('This is a readable trucking document with plenty of words. ', 10) end,
       (select v from _z)
from public.documents d where d.filename in ('misfiled.pdf','garbled.pdf');

insert into public.doc_label_audits (document_id, stored_type, model_type, model)
select id, 'POD', 'Rate Confirmation', 'qwen-test' from public.documents where filename='misfiled.pdf';
insert into public.doc_label_audits (document_id, stored_type, model_type, model)
select id, 'BOL', 'Other', 'qwen-test' from public.documents where filename='unsure.pdf';

-- 1/2. sentinel fires on the disagreement, not on the unsure opinion
select public.sentinel_scan();
select is(
  (select category||'/'||severity from public.trux_insights
    where dedup_key = 'doc_misfiled:'||(select id from public.documents where filename='misfiled.pdf')),
  'ops/warn', 'misfiled doc fires an ops warn');
select is(
  (select count(*) from public.trux_insights
    where dedup_key = 'doc_misfiled:'||(select id from public.documents where filename='unsure.pdf')),
  0::bigint, 'an unsure (Other) opinion never disputes a human label');

-- 3. office relabels the doc → finding auto-resolves on the next scan
update public.documents set doc_type='Rate Confirmation' where filename='misfiled.pdf';
select public.sentinel_scan();
select is(
  (select status from public.trux_insights
    where dedup_key = 'doc_misfiled:'||(select id from public.documents where filename='misfiled.pdf')),
  'resolved', 'relabeling the doc resolves the misfile warning');

-- 4-7. OCR quality verdicts
select is(
  (select x->>'verdict' from jsonb_array_elements(public.doc_ocr_quality_report(50)->'rescan_queue') x
    where (x->>'document_id')::bigint = (select id from public.documents where filename='garbled.pdf')),
  'garbled', 'symbol soup is verdicted garbled');
select is(((public.doc_ocr_quality_report(50))->>'no_text')::int >= 1, true, 'image-only docs counted as no_text');
select is(
  (select count(*) from jsonb_array_elements(public.doc_ocr_quality_report(50)->'rescan_queue') x
    where (x->>'document_id')::bigint = (select id from public.documents where filename='misfiled.pdf')),
  0::bigint, 'readable doc stays out of the re-scan queue');
select is(
  (select count(*) from jsonb_array_elements(public.doc_ocr_quality_report(50)->'rescan_queue') x
    where (x->>'document_id')::bigint = (select id from public.documents where filename='unsure.pdf')),
  0::bigint, 'image-only docs go to the vision queue, not the re-scan list');

-- 8/9. more-like-this (#108): identical embeddings rank as ~1.0 similar;
-- the source doc itself is excluded
select is(
  (select x->>'filename' from jsonb_array_elements(
     public.similar_documents((select id from public.documents where filename='misfiled.pdf'), 5)) x limit 1),
  'garbled.pdf', 'identical-embedding doc ranks first for more-like-this');
select is(
  (select count(*) from jsonb_array_elements(
     public.similar_documents((select id from public.documents where filename='misfiled.pdf'), 5)) x
    where x->>'filename' = 'misfiled.pdf'),
  0::bigint, 'a doc is never similar to itself');

-- 10/11. storage usage (#112): totals include the fixtures; by_type keyed
update public.documents set size_bytes = 1000 where filename in ('misfiled.pdf','garbled.pdf','unsure.pdf');
select is(((public.storage_usage_report())->>'total_bytes')::bigint >= 3000, true, 'storage rollup sums size_bytes');
select is(
  ((public.storage_usage_report())->'by_type'->'BOL'->>'docs')::int >= 1,
  true, 'by_type rollup carries the BOL bucket');

-- 12. role gate
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000a2'::uuid, 'audit-driver@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-0000000000a2';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a2"}', true);
select is(public.doc_ocr_quality_report(10), null, 'driver role gets null from OCR report');

select * from finish();
rollback;

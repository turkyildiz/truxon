-- R9 #106: BOL↔POD pairing report — the broken pair is named, the complete
-- pair is counted, and role gating holds.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f1'::uuid, 'pair-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000f1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000f1"}', true);

insert into public.customers (company_name) values ('Pair Broker');
insert into public.loads (customer_id, rate, status, notes, delivery_time)
  select id, 900, 'pending', 'pair-ok', now() - interval '2 days' from public.customers where company_name='Pair Broker';
insert into public.loads (customer_id, rate, status, notes, delivery_time)
  select id, 800, 'pending', 'pair-podonly', now() - interval '1 day' from public.customers where company_name='Pair Broker';
select set_config('app.load_rpc','1',true);
update public.loads set status='delivered' where notes in ('pair-ok','pair-podonly');
select set_config('app.load_rpc','',true);

insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path)
select 'load', id, t.doc_type, t.doc_type||'.pdf', 'test/'||t.doc_type
from public.loads l, (values ('BOL'),('POD')) t(doc_type) where l.notes='pair-ok';
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path)
select 'load', id, 'POD', 'pod.pdf', 'test/pod2' from public.loads where notes='pair-podonly';

select is(((public.doc_pairing_report(30))->>'paired')::int >= 1, true, 'complete pair counted');
select is(((public.doc_pairing_report(30))->>'pod_only')::int >= 1, true, 'POD-without-BOL counted');
select is(
  (select x->>'missing' from jsonb_array_elements(public.doc_pairing_report(30)->'broken_pairs') x
    where (x->>'load_id')::bigint = (select id from public.loads where notes='pair-podonly')),
  'BOL', 'broken pair names the missing BOL');
select is(
  (select count(*) from jsonb_array_elements(public.doc_pairing_report(30)->'broken_pairs') x
    where (x->>'load_id')::bigint = (select id from public.loads where notes='pair-ok')),
  0::bigint, 'paired load is not in the worklist');

-- role gate: drivers get null
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f2'::uuid, 'pair-driver@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-0000000000f2';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000f2"}', true);
select is(public.doc_pairing_report(30), null, 'driver role gets null from the pairing report');

select * from finish();
rollback;

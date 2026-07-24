-- R9 #153: the omnibox finds paperwork — documents match on filename or type,
-- carry their owning entity, and the whole search stays office-only.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000181'::uuid, 'gs-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000181';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000181"}', true);

insert into public.customers (company_name) values ('Search Broker');
insert into public.loads (customer_id, rate, miles, status, load_number)
select id, 1000, 300, 'completed', 'SRCH-77' from public.customers where company_name='Search Broker';
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path)
select 'load', l.id, 'Rate Confirmation', 'tql_ratecon_4412.pdf', 'test/srch-1'
  from public.loads l where l.load_number = 'SRCH-77';

-- 1-3. filename match carries the entity and the load number in the label
select is((select jsonb_array_length(public.global_search('tql_ratecon')->'documents')), 1,
  'filename fragment finds the document');
select is((select public.global_search('tql_ratecon')->'documents'->0->>'entity_type'), 'load',
  'result carries its owning entity');
select ok((select public.global_search('tql_ratecon')->'documents'->0->>'label' like '%SRCH-77%'),
  'label names the load it belongs to');

-- 4. doc_type matches too
select ok((select jsonb_array_length(public.global_search('Rate Confirmation')->'documents') >= 1),
  'doc type text matches');

-- 5. drivers are refused (whole search, unchanged)
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000182'::uuid, 'gs-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000182';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000182"}', true);
select throws_ok($$ select public.global_search('anything') $$,
  'Not enough permissions', 'driver role is refused');

select * from finish();
rollback;

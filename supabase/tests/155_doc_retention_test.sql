-- Doc retention: coverage math per entity class.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000155'::uuid, 'dr@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000155';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000155"}', true);

insert into public.customers (company_name) values ('DR Broker');
insert into public.loads (customer_id, rate, miles, status, delivery_time)
select (select id from public.customers where company_name='DR Broker'), 1000, 400, 'completed', now() - interval '2 days'
  from generate_series(1, 2);
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, content_type, size_bytes)
values ('load', (select min(id) from public.loads), 'POD', 'p.pdf', 't/p.pdf', 'application/pdf', 10);

select is((public.doc_retention_report(90)->'loads'->>'pod_pct')::int, 50, '1 of 2 loads has a POD = 50%');
select is((public.doc_retention_report(90)->'loads'->>'missing_pod')::int, 1, 'the gap is counted');

select * from finish();
rollback;

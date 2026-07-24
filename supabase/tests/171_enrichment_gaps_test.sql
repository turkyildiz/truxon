-- R9 #138: the enrichment residue report — blanks counted per field, dead
-- ends (no source left to mine) called out for a phone call, not more AI.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000179'::uuid, 'eg-acct@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000179';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000179"}', true);

-- Full: everything filled. Minable: blanks but has a customer doc.
-- DeadEnd: blanks, no docs, no mail, no QBO. Inactive: ignored entirely.
insert into public.customers (company_name, contact_person, phone, email, billing_address) values
  ('Full Broker', 'Ana', '555-1', 'a@f.test', '1 Main St');
insert into public.customers (company_name) values ('Minable Broker'), ('DeadEnd Broker');
insert into public.customers (company_name, is_active) values ('Inactive Broker', false);

insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path)
select 'customer', id, 'Contract', 'setup.pdf', 'test/eg-setup'
  from public.customers where company_name = 'Minable Broker';

create temp table eg as select public.customer_enrichment_gaps() as v;

select is((select (v->>'customers_active')::int from eg), 3, 'inactive customer excluded');
select is((select (v->>'fully_filled')::int from eg), 1, 'one customer fully filled');
select is((select (v->'blank_fields'->>'email')::int from eg), 2, 'two active customers missing email');
select is((select (v->>'dead_ends')::int from eg), 1, 'exactly one dead end (no docs, mail, or QBO)');
select is(
  (select x->>'customer' from eg, jsonb_array_elements(v->'worklist') x
    where (x->>'dead_end')::boolean limit 1),
  'DeadEnd Broker', 'the dead end is named for a phone call');

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000180'::uuid, 'eg-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000180';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000180"}', true);
select throws_ok($$ select public.customer_enrichment_gaps() $$,
  'Not enough permissions', 'driver role is refused');

select * from finish();
rollback;

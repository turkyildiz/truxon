-- R9 #128: quote drafts propose from OUR book only — a known lane yields a
-- $25-rounded suggestion and a readable reply; an unknown lane refuses to
-- invent; drivers can't call it.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000177'::uuid, 'qd-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000177';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000177"}', true);

insert into public.customers (company_name) values ('QD Broker');
-- lane book: OH->TN, three recent loads averaging $2,010
insert into public.loads (customer_id, rate, miles, status, pickup_state, delivery_state, created_at)
select id, r.rate, 420, 'completed', 'OH', 'TN', now() - interval '20 days'
  from public.customers, (values (1980), (2000), (2050)) r(rate)
 where company_name = 'QD Broker';

insert into public.quote_requests (contact_name, email, origin_city, origin_state, dest_city, dest_state, equipment) values
  ('Pat Jones', 'p@x.com', 'Toledo', 'OH', 'Nashville', 'TN', '53'' Van'),
  ('Ida Blank', 'i@x.com', 'Boise', 'ID', 'Fargo', 'ND', '');

create temp table qd as select public.draft_quote_response(
  (select id from public.quote_requests where contact_name='Pat Jones')) as v;

select is((select (v->'basis'->>'loads_90d')::int from qd), 3, 'recent lane book found');
select is((select (v->>'suggested_rate')::numeric from qd), 2000::numeric,
  'avg 2010 rounds to the nearest $25 = 2000 (no won-premium data)');
select ok((select v->>'draft_text' like 'Hi Pat,%' from qd), 'draft addresses the contact by first name');
select ok((select v->>'draft_text' like '%$2000 all-in%' from qd), 'draft carries the suggested rate');

-- unknown lane: refuses to invent
select ok((select (public.draft_quote_response(
    (select id from public.quote_requests where contact_name='Ida Blank'))->>'no_history')::boolean),
  'never-run lane returns no_history=true and no number');

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000178'::uuid, 'qd-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000178';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000178"}', true);
select throws_ok($$ select public.draft_quote_response(1) $$,
  'Not enough permissions', 'driver role is refused');

select * from finish();
rollback;

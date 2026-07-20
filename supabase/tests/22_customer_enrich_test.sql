-- Customer enrichment write path: blanks-only, never overwrite, never touch
-- company_name, per-field audit log, enriched_at stamp, and the service gate.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- a customer with SOME fields already set and some blank
insert into public.customers (company_name, contact_person, phone, email, billing_address, notes)
  values ('Acme Freight Brokers', '', '555-EXISTING', '', '', '');

-- ── service context (auth.uid() is null) ──
select set_config('request.jwt.claims', '', true);

-- fills the 4 blank allow-listed fields; phone is already set so it's skipped,
-- company_name is not allow-listed so it's ignored
select is(
  public.apply_customer_enrichment(
    (select id from public.customers where company_name = 'Acme Freight Brokers'),
    jsonb_build_object(
      'company_name', 'HACKED CO',
      'contact_person', 'Jane Broker',
      'phone', '999-NEW',
      'email', 'jane@acme.com',
      'billing_address', '1 Main St, Dallas, TX',
      'notes', 'MC# 123456'
    ),
    null::bigint, 'test-model'::text
  ), 4, 'fills exactly the 4 blank allow-listed fields');

select is((select contact_person from public.customers where company_name = 'Acme Freight Brokers'), 'Jane Broker', 'contact_person filled');
select is((select email from public.customers where company_name = 'Acme Freight Brokers'), 'jane@acme.com', 'email filled');
select is((select billing_address from public.customers where company_name = 'Acme Freight Brokers'), '1 Main St, Dallas, TX', 'billing_address filled');
select is((select notes from public.customers where company_name = 'Acme Freight Brokers'), 'MC# 123456', 'notes filled');

-- existing values are NEVER overwritten
select is((select phone from public.customers where company_name = 'Acme Freight Brokers'), '555-EXISTING', 'existing phone NOT overwritten');
-- company_name (identity) is never touched even when passed
select is((select company_name from public.customers where company_name = 'Acme Freight Brokers'), 'Acme Freight Brokers', 'company_name never changed');

-- enriched_at stamped
select isnt((select enriched_at from public.customers where company_name = 'Acme Freight Brokers'), null, 'enriched_at stamped');

-- per-field audit log (4 fills)
select is((select count(*)::int from public.customer_enrichment_log
  where customer_id = (select id from public.customers where company_name = 'Acme Freight Brokers')),
  4, 'four provenance rows logged');
select is((select new_value from public.customer_enrichment_log
  where customer_id = (select id from public.customers where company_name = 'Acme Freight Brokers') and field = 'email'),
  'jane@acme.com', 'log captures the filled value');

-- re-running fills nothing (everything now non-empty)
select is(
  public.apply_customer_enrichment(
    (select id from public.customers where company_name = 'Acme Freight Brokers'),
    jsonb_build_object('contact_person', 'Someone Else', 'phone', '111'),
    null::bigint, 'test-model'::text
  ), 0, 're-run overwrites nothing (idempotent)');

-- ── service gate: a real user (auth.uid() not null) is rejected ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001"}', true);
select throws_ok(
  $$select public.apply_customer_enrichment(1, jsonb_build_object('phone','x'), null::bigint, null::text)$$,
  'Not enough permissions', 'non-service caller is rejected');

select * from finish();
rollback;

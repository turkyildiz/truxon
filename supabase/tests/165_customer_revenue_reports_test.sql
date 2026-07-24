-- R9 #132/#135: rate-con turnaround buckets are honest (paper-first vs
-- extracted-at-booking vs booked-before-paper vs no paper), and "lost"
-- customers are only the ones quiet beyond their own cadence.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000167'::uuid, 'crr-acct@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000167';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000167"}', true);

insert into public.customers (company_name) values ('Steady Broker'), ('Gone Broker'), ('Slow Broker');

-- #132 fixtures: four loads for Steady Broker
insert into public.loads (customer_id, rate, miles, status, created_at)
select id, 1000, 300, 'completed', x.at
  from public.customers, (values
    (now() - interval '10 days'),   -- paper-first: ratecon 6h before booking
    (now() - interval '9 days'),    -- extracted-at-booking: same minute
    (now() - interval '8 days'),    -- booked-before-paper: ratecon 2 days later
    (now() - interval '7 days')     -- no ratecon at all
  ) as x(at)
 where company_name = 'Steady Broker';

insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, uploaded_at)
select 'load', l.id, 'Rate Confirmation', 'rc.pdf', 'test/rc-'||l.id,
       case row_number() over (order by l.created_at)
         when 1 then l.created_at - interval '6 hours'
         when 2 then l.created_at + interval '2 minutes'
         when 3 then l.created_at + interval '2 days'
       end
  from public.loads l
  join public.customers c on c.id = l.customer_id and c.company_name = 'Steady Broker'
 order by l.created_at limit 3;

create temp table tr as select public.ratecon_turnaround_report(30) as v;
select is((select (v->>'loads')::int from tr), 4, 'all four loads in the window');
select is((select (v->'paper_first'->>'n')::int from tr), 1, 'one paper-first booking');
select is((select (v->'paper_first'->>'median_hours')::numeric from tr), 6.0, 'six-hour turnaround measured');
select is((select (v->>'extracted_at_booking')::int from tr), 1, 'same-minute upload counts as extracted-at-booking');
select is((select (v->>'booked_before_paper')::int from tr), 1, 'phone booking with late paper is its own bucket');
select is((select (v->>'no_ratecon')::int from tr), 1, 'paperless load counted, not hidden');

-- #135 fixtures: Gone Broker ran weekly then stopped 90 days ago;
-- Slow Broker books ~quarterly and is only 80 days quiet — not lost.
insert into public.loads (customer_id, rate, miles, status, created_at, delivery_time)
select id, 2000, 400, 'completed', t.at, t.at
  from public.customers, (values
    (now() - interval '104 days'), (now() - interval '97 days'), (now() - interval '90 days')
  ) as t(at) where company_name = 'Gone Broker';
insert into public.loads (customer_id, rate, miles, status, created_at, delivery_time)
select id, 3000, 500, 'completed', t.at, t.at
  from public.customers, (values
    (now() - interval '260 days'), (now() - interval '170 days'), (now() - interval '80 days')
  ) as t(at) where company_name = 'Slow Broker';

create temp table lc as select public.lost_customer_report(45, 365) as v;
select is((select jsonb_array_length(v->'lost') from lc), 1, 'exactly one customer is truly lost');
select is((select v->'lost'->0->>'customer' from lc), 'Gone Broker',
  'the weekly shipper gone 90 days is lost; the quarterly one is not');

-- role gate
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000168'::uuid, 'crr-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000168';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000168"}', true);
select throws_ok($$ select public.lost_customer_report() $$,
  'Not enough permissions', 'driver role is refused');

select * from finish();
rollback;

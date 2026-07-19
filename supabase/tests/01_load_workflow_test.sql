-- Load lifecycle: the 6-status workflow, the cancelled branch, equipment
-- sync, and the trigger locks. Runs as a superuser with request.jwt.claims
-- pointing at a seeded admin profile — the SECURITY DEFINER RPCs read the
-- role through my_role(); RLS itself is not under test here.
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

-- ---------- seed ----------
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f01'::uuid, 'wf-admin@test.local');
select is(
  (select role::text from public.profiles where id = '00000000-0000-4000-8000-000000000f01'),
  'dispatcher',
  'profile auto-created for new auth user'
);
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f01';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f01"}', true);

insert into public.customers (company_name) values ('WF Test Broker');
insert into public.drivers (full_name, pay_per_mile) values ('WF Test Driver', 0.60);
insert into public.trucks (unit_number) values ('WF-T1');
insert into public.loads (customer_id, rate, miles)
  select id, 500, 100 from public.customers where company_name = 'WF Test Broker';

-- ---------- linear workflow ----------
select is(
  (select status::text from public.loads l join public.customers c on c.id = l.customer_id
    where c.company_name = 'WF Test Broker'),
  'pending', 'new load starts pending'
);

select throws_ok(
  $$update public.loads set status = 'assigned'
     where customer_id = (select id from public.customers where company_name = 'WF Test Broker')$$,
  'Use change_load_status() to move a load through the workflow',
  'direct status edits are rejected'
);

select throws_ok(
  $$select public.change_load_status(
      (select l.id from public.loads l join public.customers c on c.id = l.customer_id where c.company_name = 'WF Test Broker'),
      'assigned')$$,
  'Assign a driver and truck first',
  'cannot assign an unstaffed load'
);

-- Staffing a pending load auto-advances it.
update public.loads
   set driver_id = (select id from public.drivers where full_name = 'WF Test Driver'),
       truck_id  = (select id from public.trucks  where unit_number = 'WF-T1')
 where customer_id = (select id from public.customers where company_name = 'WF Test Broker');

select is(
  (select status::text from public.loads l join public.customers c on c.id = l.customer_id
    where c.company_name = 'WF Test Broker'),
  'assigned', 'staffing a pending load auto-advances to assigned'
);

select is(
  (select status::text from public.trucks where unit_number = 'WF-T1'),
  'in_use', 'assigned load marks its truck in_use'
);

select throws_ok(
  $$select public.change_load_status(
      (select l.id from public.loads l join public.customers c on c.id = l.customer_id where c.company_name = 'WF Test Broker'),
      'completed')$$,
  'Cannot go from assigned to completed',
  'status jumps are rejected'
);

select lives_ok(
  $$select public.change_load_status(
      (select l.id from public.loads l join public.customers c on c.id = l.customer_id where c.company_name = 'WF Test Broker'),
      'in_transit')$$,
  'assigned → in_transit'
);
select lives_ok(
  $$select public.change_load_status(
      (select l.id from public.loads l join public.customers c on c.id = l.customer_id where c.company_name = 'WF Test Broker'),
      'delivered')$$,
  'in_transit → delivered'
);
select lives_ok(
  $$select public.change_load_status(
      (select l.id from public.loads l join public.customers c on c.id = l.customer_id where c.company_name = 'WF Test Broker'),
      'completed')$$,
  'delivered → completed'
);

select is(
  (select status::text from public.trucks where unit_number = 'WF-T1'),
  'available', 'completing the load frees the truck'
);

select throws_ok(
  $$select public.change_load_status(
      (select l.id from public.loads l join public.customers c on c.id = l.customer_id where c.company_name = 'WF Test Broker'),
      'billed')$$,
  'Generate an invoice to mark a load billed',
  'billed requires an invoice'
);

-- ---------- cancelled branch ----------
select throws_ok(
  $$select public.cancel_load(
      (select l.id from public.loads l join public.customers c on c.id = l.customer_id where c.company_name = 'WF Test Broker'),
      'too late')$$,
  'Cannot cancel a completed load',
  'completed loads cannot be cancelled'
);

insert into public.loads (customer_id, rate, miles, notes)
  select id, 900, 250, 'wf-cancel-me' from public.customers where company_name = 'WF Test Broker';

update public.loads
   set driver_id = (select id from public.drivers where full_name = 'WF Test Driver'),
       truck_id  = (select id from public.trucks  where unit_number = 'WF-T1')
 where notes = 'wf-cancel-me';

select lives_ok(
  $$select public.cancel_load((select id from public.loads where notes = 'wf-cancel-me'), 'broker pulled the freight')$$,
  'assigned load can be cancelled'
);

select is(
  (select status::text || '|' || cancel_reason from public.loads where notes = 'wf-cancel-me'),
  'cancelled|broker pulled the freight',
  'cancel sets status and reason'
);

select is(
  (select status::text from public.trucks where unit_number = 'WF-T1'),
  'available', 'cancelling frees the truck'
);

select throws_ok(
  $$update public.loads set notes = 'sneaky edit' where notes = 'wf-cancel-me'$$,
  'Cancelled loads are locked; un-cancel first',
  'cancelled loads are locked'
);

select throws_ok(
  $$select public.change_load_status((select id from public.loads where notes = 'wf-cancel-me'), 'pending')$$,
  'Load is cancelled; use uncancel_load() first',
  'change_load_status refuses cancelled loads (NULL array_position hole is closed)'
);

select throws_ok(
  $$select public.change_load_status(
      (select l.id from public.loads l join public.customers c on c.id = l.customer_id
        where c.company_name = 'WF Test Broker' and l.status = 'completed'),
      'cancelled')$$,
  'Use cancel_load() to cancel a load',
  'change_load_status refuses to cancel'
);

select is(
  (select (public.uncancel_load((select id from public.loads where notes = 'wf-cancel-me'))).status::text),
  'pending', 'uncancel returns the load to pending'
);

select * from finish();
rollback;

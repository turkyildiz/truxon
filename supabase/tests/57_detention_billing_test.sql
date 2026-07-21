-- Detention → money: detected detention proposes an accessorial, the office
-- approves it, and create_invoice folds it into the invoice total and marks it
-- invoiced. Rejected ones never bill.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f57'::uuid, 'detbill@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f57';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f57"}', true);

insert into public.customers (company_name) values ('DetBill Broker');
insert into public.trucks (unit_number, status) values ('DB1', 'available');

-- completed load, delivered yesterday; truck sat at the consignee 4 hours
-- (240 min dwell − 120 free = 120 min × $50/h → $100 detention)
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, truck_id,
                          delivery_lat, delivery_lon, delivery_state)
  select 'DB-1', c.id, 'completed', now() - interval '25 hours', 2000, 600, t.id, 40.0, -80.0, 'PA'
    from public.customers c, public.trucks t
   where c.company_name = 'DetBill Broker' and t.unit_number = 'DB1';
insert into public.eld_location_history (id, truck_id, lat, lng, ts)
  select gen_random_uuid(), (select id from public.trucks where unit_number = 'DB1'),
         40.0, -80.0, now() - interval '25 hours' + make_interval(mins => g * 60)
  from generate_series(0, 4) g;

select ok(public.propose_detention_accessorials() >= 1, 'detected detention proposes an accessorial');
select is(
  (select status from public.load_accessorials
    where load_id = (select id from public.loads where load_number = 'DB-1')),
  'proposed', 'proposal starts as proposed');
select is(
  (select amount from public.load_accessorials
    where load_id = (select id from public.loads where load_number = 'DB-1')),
  100.00, 'amount is server-computed from the dwell (2h over free @ $50)');
select ok(public.propose_detention_accessorials() >= 0
  and (select count(*) from public.load_accessorials
        where load_id = (select id from public.loads where load_number = 'DB-1')) = 1,
  're-proposing refreshes in place — still exactly one row');

-- approve, then bill the load
select public.decide_accessorial(
  (select id from public.load_accessorials
    where load_id = (select id from public.loads where load_number = 'DB-1')), true);
select is(
  (select status from public.load_accessorials
    where load_id = (select id from public.loads where load_number = 'DB-1')),
  'approved', 'office approval sticks');

select is(
  (select total from public.create_invoice(
     (select id from public.customers where company_name = 'DetBill Broker'),
     array[(select id from public.loads where load_number = 'DB-1')])),
  2100.00, 'invoice total = load rate + approved detention');
select is(
  (select status from public.load_accessorials
    where load_id = (select id from public.loads where load_number = 'DB-1')),
  'invoiced', 'billed accessorial flips to invoiced');

-- invoiced rows are locked
select throws_ok(
  format('select public.decide_accessorial(%s, false)',
    (select id from public.load_accessorials
      where load_id = (select id from public.loads where load_number = 'DB-1'))),
  'P0001', 'Already invoiced', 'an invoiced accessorial cannot be re-decided');

select * from finish();
rollback;

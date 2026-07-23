-- Fuel-stop analysis: the pricey stop shows its premium vs the state average.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000153'::uuid, 'fs@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000153';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000153"}', true);

insert into public.fuel_transactions (uuid, transaction_time, merchant, merchant_state, gallons, price_per_gallon, amount)
select 'fs-'||g, now() - interval '5 days',
       case when g <= 2 then 'PRICEY PLAZA' else 'CHEAP STOP' end, 'OH',
       100, case when g <= 2 then 4.00 else 3.50 end,
       case when g <= 2 then 400 else 350 end
  from generate_series(1, 4) g;

-- state avg = 3.75; pricey pays +0.25 on 200 gal = $50 premium
select is(
  (select (s->>'premium_paid')::numeric from jsonb_array_elements(public.fuel_stop_analysis(60)->'stops') s
    where s->>'merchant' = 'PRICEY PLAZA'), 50.00::numeric,
  'premium vs same-state average computed');
select ok(
  (select (s->>'premium_paid')::numeric from jsonb_array_elements(public.fuel_stop_analysis(60)->'stops') s
    where s->>'merchant' = 'CHEAP STOP') < 0,
  'the cheap stop shows a negative premium (savings)');

select * from finish();
rollback;

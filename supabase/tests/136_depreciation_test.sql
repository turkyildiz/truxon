-- Depreciation schedule: straight-line math and fully-depreciated floor.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000137'::uuid, 'dp@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000137';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000137"}', true);

insert into public.trucks (unit_number, purchase_price, purchase_date) values
  ('DP-NEW', 150000, (now() - interval '10 months')::date),
  ('DP-OLD', 60000, (now() - interval '10 years')::date),
  ('DP-BLANK', null, null);

select is(
  (select (r->>'monthly')::numeric from jsonb_array_elements(public.depreciation_schedule()->'rows') r
    where r->>'unit' = 'DP-NEW'),
  2000::numeric, 'monthly = price x 80% / 60');
select is(
  (select (r->>'book_value')::numeric from jsonb_array_elements(public.depreciation_schedule()->'rows') r
    where r->>'unit' = 'DP-OLD'),
  12000::numeric, 'fully depreciated floors at salvage (20%)');
select is((public.depreciation_schedule()->>'entered')::int, 2,
  'blank purchase data stays out, counted honestly');

select * from finish();
rollback;

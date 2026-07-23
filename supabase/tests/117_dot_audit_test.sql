-- dot_audit_pack(): callable, keys present, expired CDL surfaces.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000118'::uuid, 'da@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000118';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000118"}', true);

insert into public.drivers (full_name, status, license_number, license_expiration)
values ('Expired Eddie', 'active', 'D123', current_date - 10);

select ok((public.dot_audit_pack()) ? 'not_tracked', 'honest gaps are named');
select ok(
  (select jsonb_array_length(public.dot_audit_pack()->'cdl_expired') >= 1),
  'expired CDL surfaces in the pack');
select ok(
  (public.dot_audit_pack()->>'drivers_active')::int >= 1,
  'driver counts populate');

select * from finish();
rollback;

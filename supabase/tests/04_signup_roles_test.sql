-- Signup-metadata hardening: the profile trigger must never grant 'admin'
-- from raw_user_meta_data, must survive garbage metadata, and must default
-- sensibly. (Real admins are promoted post-creation by the admin-users edge
-- function via the service role.)
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-4000-8000-000000000a01'::uuid, 'mallory@test.local',
          '{"role": "admin", "username": "mallory", "full_name": "Mallory"}'::jsonb);
select is(
  (select role::text from public.profiles where id = '00000000-0000-4000-8000-000000000a01'),
  'driver',
  'metadata role=admin is refused (granted least-privilege driver)'
);

insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-4000-8000-000000000a02'::uuid, 'driver@test.local',
          '{"role": "driver", "username": "drv"}'::jsonb);
select is(
  (select role::text from public.profiles where id = '00000000-0000-4000-8000-000000000a02'),
  'driver',
  'legitimate non-admin roles pass through'
);

insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-4000-8000-000000000a03'::uuid, 'garbage@test.local',
          '{"role": "superuser!"}'::jsonb);
select is(
  (select role::text from public.profiles where id = '00000000-0000-4000-8000-000000000a03'),
  'driver',
  'unknown role text falls back instead of throwing'
);

insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-000000000a04'::uuid, 'plain@test.local');
select is(
  (select role::text from public.profiles where id = '00000000-0000-4000-8000-000000000a04'),
  'driver',
  'absent metadata defaults to least-privilege driver'
);
select is(
  (select username from public.profiles where id = '00000000-0000-4000-8000-000000000a04'),
  'plain',
  'username falls back to the email local part'
);

select * from finish();
rollback;

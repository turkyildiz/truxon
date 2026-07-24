-- READINESS #183: the last-active-admin guards (S-12). protect_last_admin() and
-- protect_last_admin_delete() are DB-level triggers that refuse to demote,
-- deactivate, OR delete the final active admin — the invariant that keeps the
-- owner from getting locked out of their own system (or an attacker from
-- collapsing all admin access). They must block the last one on every path,
-- allow it the moment a second admin exists, and recompute on live state.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

-- two admins (accounts default to dispatcher; promote directly)
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000ad01'::uuid, 'admin-a@test.local'),
  ('00000000-0000-4000-8000-00000000ad02'::uuid, 'admin-b@test.local');
update public.profiles set role='admin'
  where id in ('00000000-0000-4000-8000-00000000ad01','00000000-0000-4000-8000-00000000ad02');

-- baseline: exactly the two admins we made are active
select is((select count(*)::int from public.profiles where role='admin' and is_active), 2,
  '0. two active admins to start');

-- with a peer still admin, demoting one is fine
select lives_ok(
  $$update public.profiles set role='dispatcher' where id='00000000-0000-4000-8000-00000000ad01'$$,
  '1. an admin can be demoted while another active admin remains');

-- B is now the last active admin — demotion is refused
select throws_ok(
  $$update public.profiles set role='dispatcher' where id='00000000-0000-4000-8000-00000000ad02'$$,
  'Cannot demote or deactivate the last active admin', '2. the last admin cannot be demoted');

-- ...and deactivation is refused too
select throws_ok(
  $$update public.profiles set is_active=false where id='00000000-0000-4000-8000-00000000ad02'$$,
  'Cannot demote or deactivate the last active admin', '3. the last admin cannot be deactivated');

-- the guard only fences role/active — the last admin can still edit other fields
select lives_ok(
  $$update public.profiles set full_name='Still The Admin' where id='00000000-0000-4000-8000-00000000ad02'$$,
  '4. the last admin can still update non-privilege fields');

-- restore a second admin, and now deactivating B is allowed
select lives_ok(
  $$update public.profiles set role='admin' where id='00000000-0000-4000-8000-00000000ad01'$$,
  '5. promoting a second admin lifts the lock');
select lives_ok(
  $$update public.profiles set is_active=false where id='00000000-0000-4000-8000-00000000ad02'$$,
  '6. with two admins, one may be deactivated — and A is now the last standing');

-- A is the only active admin again — DELETE is fenced too (a second lockout path)
select throws_ok(
  $$delete from public.profiles where id='00000000-0000-4000-8000-00000000ad01'$$,
  'Cannot delete the last active admin', '7. the last admin row cannot be deleted');

-- reactivate B and now A may be deleted (B carries admin forward)
update public.profiles set is_active=true where id='00000000-0000-4000-8000-00000000ad02';
select lives_ok(
  $$delete from public.profiles where id='00000000-0000-4000-8000-00000000ad01'$$,
  '8. with a second active admin, an admin row may be deleted');

select * from finish();
rollback;

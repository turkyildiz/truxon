-- READINESS #188: rate limiters. check_rate_limit() (per-user) and
-- check_ip_rate_limit() (per-IP, pre-auth) are the throttles that blunt
-- credential-stuffing, signup floods, and abusive RPC hammering. Each returns
-- true while under budget and false once the window is full, buckets are keyed
-- independently (per action / per identity), and events outside the window are
-- pruned so the budget actually resets. Unauthenticated callers are refused.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000c101'::uuid, 'rl@test.local');

-- ═══ per-user limiter ═══
-- unauthenticated: refused outright
select set_config('request.jwt.claims', '{}', true);
select throws_ok(
  $$select public.check_rate_limit('login', 3)$$,
  'Not authenticated', '1. an unauthenticated caller is refused');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000c101"}', true);
-- budget of 3 for action "login": first three pass, fourth is throttled
select is(public.check_rate_limit('login', 3), true,  '2. login attempt 1 under budget');
select is(public.check_rate_limit('login', 3), true,  '3. login attempt 2 under budget');
select is(public.check_rate_limit('login', 3), true,  '4. login attempt 3 under budget');
select is(public.check_rate_limit('login', 3), false, '5. login attempt 4 is throttled');
-- a different action has its own budget
select is(public.check_rate_limit('export', 3), true, '6. a different action has an independent budget');

-- window pruning: an event older than the window does not count, so the budget resets
insert into public.rate_limit_events (user_id, action, created_at)
values ('00000000-0000-4000-8000-00000000c101', 'digest', now() - interval '2 hours');
select is(public.check_rate_limit('digest', 1, interval '1 hour'), true,
  '7. an event outside the window is pruned and does not consume the budget');

-- ═══ per-IP limiter (no auth; keyed on the address) ═══
select is(public.check_ip_rate_limit('203.0.113.9', 'signup', 2), true,  '8. IP signup attempt 1 under budget');
select is(public.check_ip_rate_limit('203.0.113.9', 'signup', 2), true,  '9. IP signup attempt 2 under budget');
select is(public.check_ip_rate_limit('203.0.113.9', 'signup', 2), false, '10. IP signup attempt 3 is throttled');
-- a different address is a different bucket
select is(public.check_ip_rate_limit('198.51.100.7', 'signup', 2), true,
  '11. a different IP has an independent budget');

select * from finish();
rollback;

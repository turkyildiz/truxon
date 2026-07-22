-- Honeypot canaries: decoys serve plausible fakes, record who touched them,
-- surface a Sentinel finding with evidence, and Forest's own SQL tool is
-- physically unable to trip the wire.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f91'::uuid, 'hp@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f91';
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000f91","role":"authenticated","email":"hp@test.local"}', true);

-- (1) decoys look like real tables with real data — checked AS the API role
-- (view functions execute with caller privileges; a superuser session would
-- mask a missing grant, which is exactly what happened on first deploy)
set local role authenticated;
select ok((select count(*) from public.api_keys) >= 3, 'decoy api_keys serves plausible rows');
select ok((select count(*) from public.bank_accounts) >= 2, 'decoy bank_accounts serves plausible rows');
reset role;

-- (2) the touch was recorded with the caller''s identity
select ok(exists(select 1 from app_private.honeypot_hits
                  where object = 'api_keys'
                    and jwt_claims->>'sub' = '00000000-0000-4000-8000-000000000f91'),
  'hit recorded with the caller''s JWT identity');

-- (3) sentinel turns it into a critical finding (named account = critical)
select public.sentinel_scan();
select ok(exists(select 1 from public.trux_insights
                  where dedup_key like 'honeypot:api_keys:%'
                    and severity = 'critical' and status <> 'resolved'),
  'sentinel fires a critical honeypot finding for a named-account hit');

-- (4) click-through detail carries the why + per-hit evidence
select ok((select d->>'why' from (
             select public.insight_detail((select id from public.trux_insights
                                            where dedup_key like 'honeypot:api_keys:%' limit 1)) d) x)
          ilike '%decoy%',
  'insight_detail explains the honeypot in plain English');
select ok((select jsonb_array_length(d->'records') from (
             select public.insight_detail((select id from public.trux_insights
                                            where dedup_key like 'honeypot:api_keys:%' limit 1)) d) x) >= 1,
  'insight_detail lists the individual hits as evidence');

-- (5) Forest''s SQL tool refuses the decoys by name (no self-inflicted alarms)
select throws_like(
  'select public.trux_query(''select * from api_keys'')',
  '%restricted%',
  'trux_query refuses to touch honeypot objects');

select * from finish();
rollback;

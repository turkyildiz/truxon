-- R9 #124 prep: transcript shelf + search. Office can search, websearch
-- syntax works, drivers are refused, and authenticated can't write (the
-- recorder doesn't exist yet — writes are service_role-only by design).
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000165'::uuid, 'rt-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000165';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000166'::uuid, 'rt-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000166';

-- fixtures land as postgres (stands in for the future service_role writer)
insert into public.radio_transcripts (spoken_at, speaker_name, duration_sec, transcript) values
  (now() - interval '1 hour', 'Yusuf', 8.2, 'stuck at the shipper two hours now, detention clock started'),
  (now() - interval '2 hours', 'Marco', 4.0, 'fuel stop at the Pilot exit forty'),
  (now() - interval '40 days', 'Yusuf', 5.0, 'old detention chatter outside the window');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000165"}', true);

-- 1. plain word match with a snippet
select is((select jsonb_array_length(public.search_radio_transcripts('detention', 30)->'hits')), 1,
  'detention matches only the in-window transmission');
select ok((select public.search_radio_transcripts('detention', 30)->'hits'->0->>'snippet' like '%[[detention]]%'),
  'snippet marks the hit with safe [[ ]] delimiters, not HTML');
-- 3. websearch negation
select is((select jsonb_array_length(public.search_radio_transcripts('fuel -detention', 30)->'hits')), 1,
  'websearch negation works');
-- 4. total_stored is honest about the archive size
select is((select (public.search_radio_transcripts('detention', 30)->>'total_stored')::int), 3,
  'total_stored counts the whole shelf');

-- 5. drivers refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000166"}', true);
select throws_ok($$ select public.search_radio_transcripts('anything') $$,
  'Not enough permissions', 'driver role is refused');

-- 6. no recorder exists: authenticated cannot insert
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000165"}', true);
select throws_like($$ insert into public.radio_transcripts (spoken_at, transcript) values (now(), 'x') $$,
  '%permission denied%', 'authenticated has no INSERT — the shelf fills only when the owner approves a recorder');
reset role;

select * from finish();
rollback;

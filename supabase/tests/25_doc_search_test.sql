-- Document search request queue: enqueue role gate + length check, service-only
-- claim/complete, and the claim → processing → done lifecycle.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

-- an admin and a driver to exercise the role gates
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000005a1'::uuid, 'admin@test.local'),
  ('00000000-0000-4000-8000-0000000005d2'::uuid, 'driver@test.local');
update public.profiles set role = 'admin'  where id = '00000000-0000-4000-8000-0000000005a1';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-0000000005d2';

-- ── enqueue: admin allowed ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000005a1"}', true);
select isnt(public.enqueue_doc_search('detention and lumper terms', null), null, 'admin can enqueue a search');
select is((select status from public.doc_search_requests order by id desc limit 1), 'pending', 'new request is pending');
select is((select requester from public.doc_search_requests order by id desc limit 1),
          '00000000-0000-4000-8000-0000000005a1'::uuid, 'requester is the caller');

-- ── enqueue: length + role gates ──
select throws_like($$ select public.enqueue_doc_search('x', null) $$, '%too short%', 'one-char query rejected');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000005d2"}', true);
select throws_like($$ select public.enqueue_doc_search('reefer temperature', null) $$,
  '%Not enough permissions%', 'driver cannot enqueue');

-- ── claim + complete: service context (no auth.uid) ──
select set_config('request.jwt.claims', '', true);
select is((select count(*)::int from public.claim_doc_search()), 1, 'service claims the pending request');
select is((select status from public.doc_search_requests order by id desc limit 1), 'processing', 'claimed → processing');

do $$
declare v_id bigint;
begin
  select id into v_id from public.doc_search_requests order by id desc limit 1;
  perform public.complete_doc_search(v_id, '[{"document_id":1,"similarity":0.9}]'::jsonb, null);
end $$;
select is((select status from public.doc_search_requests order by id desc limit 1), 'done', 'complete → done with results');

select * from finish();
rollback;

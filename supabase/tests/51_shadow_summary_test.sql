-- Shadow review: the summary RPC aggregates the observation ledger for the
-- reviewer header; a dispatcher can read + mark-review observations under RLS;
-- non-office roles see nothing.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

-- seed the ledger the way the shadow poller does (service path, no auth.uid)
select ok(public.log_observation(jsonb_build_object(
  'message_id', 'm-51-1', 'received_at', now() - interval '2 hours',
  'sender_email', 'broker@tql.com', 'subject', 'Rate confirmation 12345',
  'classification', 'rate_con', 'summary', 'TQL rate con, Chicago -> Dallas $2400',
  'would_action', 'create_load', 'would_detail', 'Would create load for TQL',
  'confidence', 'high')) is not null, 'poller logs a rate con');
select ok(public.log_observation(jsonb_build_object(
  'message_id', 'm-51-2', 'received_at', now() - interval '1 hour',
  'sender_email', 'ops@select.com', 'subject', 'POD load 88',
  'classification', 'pod', 'would_action', 'file_document')) is not null,
  'poller logs a POD');
select is(public.log_observation(jsonb_build_object(
  'message_id', 'm-51-2', 'classification', 'pod')), null,
  'duplicate message_id is a no-op (exactly-once)');

-- dispatcher reviews
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f51'::uuid, 'shadow@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000f51';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f51"}', true);
select set_config('role', 'authenticated', true);

select is((public.shadow_summary()->>'total')::int, 2, 'summary counts both observations');
select is((public.shadow_summary()->'by_classification'->>'rate_con')::int, 1,
  'classification breakdown is present');

update public.trux_observations set reviewed = true, review_note = 'looks right'
 where message_id = 'm-51-1';
select is((public.shadow_summary()->>'unreviewed')::int, 1,
  'marking reviewed under RLS drops the unreviewed count');

-- a driver sees nothing
reset role;
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f52'::uuid, 'shadowdrv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f52';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f52"}', true);
select set_config('role', 'authenticated', true);
select is(public.shadow_summary(), null, 'non-office role gets no summary');

select * from finish();
rollback;

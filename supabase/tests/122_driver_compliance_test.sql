-- Driver compliance program: bare driver fires MVR/pool/Clearinghouse warns,
-- a maintained file stays quiet, and the event log rejects junk kinds.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000123'::uuid, 'dc@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000123';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000123"}', true);

insert into public.drivers (full_name, status) values ('DC Bare', 'active');
insert into public.drivers (full_name, status, drug_consortium, drug_pool_enrolled_on)
values ('DC Clean', 'active', 'TestPool Inc', current_date - 200);
insert into public.driver_compliance_events (driver_id, kind, occurred_on, reviewer)
values ((select id from public.drivers where full_name='DC Clean'), 'mvr_review', current_date - 100, 'Office'),
       ((select id from public.drivers where full_name='DC Clean'), 'clearinghouse_query', current_date - 100, 'Office');

select public.sentinel_scan();

select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'mvr:'||(select id from public.drivers where full_name='DC Bare')||':none'
    and severity = 'warn'), 'no MVR review on record = warn');
select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'drugpool:'||(select id from public.drivers where full_name='DC Bare')
    and severity = 'warn'), 'no pool enrollment = warn');
select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'clearinghouse:'||(select id from public.drivers where full_name='DC Bare')||':none'
    and severity = 'warn'), 'no Clearinghouse query = warn');
select ok(not exists (select 1 from public.trux_insights
  where dedup_key in ('mvr:'||(select id from public.drivers where full_name='DC Clean')||':none',
                      'drugpool:'||(select id from public.drivers where full_name='DC Clean'),
                      'clearinghouse:'||(select id from public.drivers where full_name='DC Clean')||':none')),
  'maintained compliance file stays quiet');
select ok((select detail from public.trux_insights
  where dedup_key = 'mvr:'||(select id from public.drivers where full_name='DC Bare')||':none')
  ilike '%391.25%', 'finding cites the regulation');
select throws_ok(
  $$insert into public.driver_compliance_events (driver_id, kind)
    values ((select id from public.drivers where full_name='DC Bare'), 'vibe_check')$$,
  '23514', null, 'unknown event kind rejected');

select * from finish();
rollback;

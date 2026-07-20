-- Northstar night flip: newly-instrumented playbook metrics now report live, and
-- overall coverage rose past 80/1000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f47'::uuid, 'pb@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f47';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f47"}', true);

select is((select status from public.playbook_metrics where number=213), 'live', 'On-Time Delivery % is now live (ELD)');
select is((select status from public.playbook_metrics where number=227), 'live', 'Detention Incidence % is now live');
select is((select status from public.playbook_metrics where number=658), 'live', 'CSA Unsafe Driving percentile is now live (FMCSA)');
select isnt((select source from public.playbook_metrics where number=54), '', 'flipped metrics record their compute source');
select cmp_ok((public.playbook_coverage()->'by_status'->>'live')::int, '>=', 80, 'live coverage rose past 80/1000');

select * from finish();
rollback;

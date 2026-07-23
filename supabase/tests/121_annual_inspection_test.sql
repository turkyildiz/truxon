-- Annual DOT inspection sentinel: none-on-record = critical, current = quiet.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000122'::uuid, 'ai@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000122';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000122"}', true);

insert into public.trucks (unit_number) values ('AI-NONE'), ('AI-CURRENT');
insert into public.maintenance_records (equipment_type, truck_id, service_type, status, date_completed, description)
values ('truck', (select id from public.trucks where unit_number='AI-CURRENT'),
        'dot_inspection', 'completed', current_date - 100, 'Annual inspection');

select public.sentinel_scan();

select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'annual_insp:'||(select id from public.trucks where unit_number='AI-NONE')||':none'
    and severity = 'critical'), 'no inspection on record = critical');
select ok(not exists (select 1 from public.trux_insights
  where dedup_key like 'annual_insp:'||(select id from public.trucks where unit_number='AI-CURRENT')||':%'),
  'current inspection stays quiet');
select ok((select detail from public.trux_insights
  where dedup_key = 'annual_insp:'||(select id from public.trucks where unit_number='AI-NONE')||':none')
  ilike '%OOS violation%', 'finding explains the stakes');

select * from finish();
rollback;

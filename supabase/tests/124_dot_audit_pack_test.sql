-- dot_audit_pack v2: counts the formal dot_inspection service type, sees the
-- new compliance program, and no longer claims tracked things are untracked.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000125'::uuid, 'ap@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000125';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000125"}', true);

insert into public.trucks (unit_number) values ('AP-1');
insert into public.maintenance_records (equipment_type, truck_id, service_type, status, date_completed, description)
values ('truck', (select id from public.trucks where unit_number='AP-1'),
        'dot_inspection', 'completed', current_date - 30, 'x');
insert into public.drivers (full_name, status) values ('AP Driver', 'active');
insert into public.driver_compliance_events (driver_id, kind, occurred_on)
values ((select id from public.drivers where full_name='AP Driver'), 'mvr_review', current_date - 10);

select ok((public.dot_audit_pack()->>'annual_inspection_current')::int >= 1,
  'formal dot_inspection service type counts as a current annual');
select ok((public.dot_audit_pack()->>'mvr_reviewed_12m')::int >= 1,
  'MVR reviews from the compliance log are counted');
select ok(not (public.dot_audit_pack()->'not_tracked')::text ilike '%medical card%',
  'medical card no longer claimed untracked');
select ok((public.dot_audit_pack()->'not_tracked')::text ilike '%previous-employer%',
  'still honest about the real gap');

select * from finish();
rollback;

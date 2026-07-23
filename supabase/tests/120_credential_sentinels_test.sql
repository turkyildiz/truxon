-- Credential expiry ladder: CDL / medical card / plate escalate by proximity.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000121'::uuid, 'cr@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000121';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000121"}', true);

insert into public.drivers (full_name, status, license_expiration, medical_card_expiry)
values ('Larry Ladder', 'active', current_date + 45, current_date - 3),
       ('Fine Fiona', 'active', current_date + 120, current_date + 120),
       ('Gone Gary', 'terminated', current_date - 10, current_date - 10);
insert into public.trucks (unit_number, plate_number, plate_expiry, status)
values ('CR-1', 'PLT123', current_date + 5, 'available');

select public.sentinel_scan();

select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'cred:cdl:'||(select id from public.drivers where full_name='Larry Ladder')||':60d'
    and severity = 'info'), 'CDL at 45d = info stage');
select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'cred:medcard:'||(select id from public.drivers where full_name='Larry Ladder')||':expired'
    and severity = 'critical' and detail ilike '%OOS violation%'), 'expired med card = critical');
select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'cred:plate:'||(select id from public.trucks where unit_number='CR-1')||':7d'
    and severity = 'critical'), 'plate at 5d = critical stage');
select ok(not exists (select 1 from public.trux_insights
  where dedup_key like 'cred:%:'||(select id from public.drivers where full_name='Fine Fiona')||':%'),
  'far-future credentials stay quiet');
select ok(not exists (select 1 from public.trux_insights
  where dedup_key like 'cred:%:'||(select id from public.drivers where full_name='Gone Gary')||':%'),
  'terminated drivers are not policed');

select * from finish();
rollback;

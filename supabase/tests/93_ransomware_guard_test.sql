-- Ransomware guard (JadePuffer/ENCFORGE class): destructive DDL and TRUNCATE
-- on business tables are blocked and rolled back; migrations override with
-- app.allow_drops; the guard cannot be silently removed.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f94'::uuid, 'rg@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f94';
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000f94","role":"authenticated","email":"rg@test.local"}', true);

-- a real (non-temp) public table stands in for a business table
create table public._ransom_probe (id int);

-- (1) DROP is blocked
select throws_like('drop table public._ransom_probe', '%ransomware guard%',
  'DROP TABLE on a public table is blocked');
-- (2) the table still exists after the blocked drop
select ok(to_regclass('public._ransom_probe') is not null, 'the table survives the blocked drop');
-- (3) TRUNCATE on a crown-jewel table is blocked (trux_insights: a leaf table,
-- so we exercise the guard rather than Postgres's FK-reference refusal)
select throws_like('truncate public.trux_insights', '%ransomware guard%',
  'TRUNCATE on a crown-jewel table is blocked');

-- (4) legitimate schema change works with the explicit override
set local app.allow_drops = 'on';
select lives_ok('drop table public._ransom_probe',
  'with app.allow_drops=on a legitimate drop succeeds');
set local app.allow_drops = 'off';

-- (6) after the override is off, the guard is active again
create table public._ransom_probe2 (id int);
select throws_like('drop table public._ransom_probe2', '%ransomware guard%',
  'the guard re-arms once the override is cleared');

select * from finish();
rollback;

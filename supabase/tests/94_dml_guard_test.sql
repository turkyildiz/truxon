-- DML-layer ransomware guard (20260722006001): bulk DELETE on a crown jewel is
-- blocked, a bypass flag releases it, and an abnormally large UPDATE is flagged
-- (but allowed, so legitimate syncs never break).
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into public.customers (company_name)
  select 'dmlguard_' || g from generate_series(1, 600) g;

-- (1) a small delete stays under the threshold and is allowed
select lives_ok(
  $$delete from public.customers where company_name = 'dmlguard_1'$$,
  'small DELETE under threshold is allowed');

-- (2) a bulk delete of a crown jewel is blocked and rolled back
select throws_like(
  $$delete from public.customers where company_name like 'dmlguard_%'$$,
  '%BLOCKED by ransomware guard: bulk DELETE%',
  'bulk DELETE on a crown jewel is blocked');

-- (3) the explicit maintenance bypass releases it
set local app.allow_bulk_dml = 'on';
select lives_ok(
  $$delete from public.customers where company_name like 'dmlguard_%'$$,
  'bulk DELETE allowed with app.allow_bulk_dml = on');
reset app.allow_bulk_dml;

-- (4) a large single-statement UPDATE is ALLOWED (alarm-only, never blocks syncs)
insert into public.customers (company_name)
  select 'dmlguard2_' || g from generate_series(1, 600) g;
select lives_ok(
  $$update public.customers set updated_at = now() where company_name like 'dmlguard2_%'$$,
  'large UPDATE is allowed (alarm-only)');

-- (5) …but it left a critical security insight for review
select ok(
  exists(select 1 from public.trux_insights where dedup_key like 'ransom_dml:UPDATE:%'),
  'large UPDATE raised a security insight');

select * from finish();
rollback;

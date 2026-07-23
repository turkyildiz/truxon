-- ML readiness: counts + trainable bar honesty.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000146'::uuid, 'ml@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000146';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000146"}', true);

insert into public.trucks (unit_number) values ('ML-1');
insert into public.truck_weekly_features (week_start, truck_id, miles, mpg, breakdown_next_4w)
values (public.trux_week_start(current_date) - 7, (select id from public.trucks where unit_number='ML-1'), 2000, 6.5, false);

select is((public.breakdown_ml_readiness()->>'rows_banked')::int, 1, 'rows counted');
select is((public.breakdown_ml_readiness()->>'trainable')::boolean, false,
  'one row is honestly not trainable');

select * from finish();
rollback;

-- Equipment-gap-adjusted operating ratio: truck payments the GL can't see
-- raise the true ratio; the plain ratio is untouched.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000135'::uuid, 'cf@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000135';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000135"}', true);

insert into public.gl_monthly (month, account, grp, amount, source) values
  (date_trunc('month', now())::date, 'Freight Income', 'income', 10000, 'test'),
  (date_trunc('month', now())::date, 'Fuel', 'expense', 8000, 'test');
insert into public.trucks (unit_number, monthly_payment) values ('CF-1', 500);

select is((public.gl_cfo_snapshot()->>'operating_ratio_12m')::numeric, 80.0::numeric,
  'plain operating ratio = GL costs / GL revenue');
select is((public.gl_cfo_snapshot()->>'operating_ratio_equip_adj')::numeric, 140.0::numeric,
  'equip-adjusted ratio adds the annualized payment gap (500x12 on 10k revenue)');

select * from finish();
rollback;

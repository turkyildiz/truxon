-- R3 #7: recommendation rules on controlled customers (fuel/GL empty locally
-- so gl_all_in_rpm = 0 → margin = revenue; drive the rules via pay history).
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f81'::uuid, 'kf@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f81';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f81"}', true);

insert into public.customers (company_name) values ('Fast Payer Co'), ('Slow Payer Co');

-- both shipped one profitable load
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles)
select 'KF-' || row_number() over (), id, 'completed', now() - interval '10 days', 3000, 900
  from public.customers where company_name in ('Fast Payer Co', 'Slow Payer Co');

-- pay history: fast pays in 20 days, slow pays in 120
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, paid_at)
select 'KFI-1', id, now() - interval '40 days', now() - interval '10 days', 3000, 'paid', now() - interval '20 days'
  from public.customers where company_name = 'Fast Payer Co';
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, paid_at)
select 'KFI-2', id, now() - interval '150 days', now() - interval '120 days', 3000, 'paid', now() - interval '30 days'
  from public.customers where company_name = 'Slow Payer Co';

select is((select k.recommendation from public.customer_keep_fire(365) k
            where k.company_name = 'Fast Payer Co'), 'grow',
  'profitable + pays in 20 days = grow');
select is((select k.recommendation from public.customer_keep_fire(365) k
            where k.company_name = 'Slow Payer Co'), 'keep',
  'profitable but pays in 120 days = keep (not grow)');
select matches((select k.reason from public.customer_keep_fire(365) k
                 where k.company_name = 'Slow Payer Co'),
  'pays in 120 days', 'reason names the pay problem');

select set_config('request.jwt.claims', null, true);
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f82'::uuid, 'kf-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f82';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f82"}', true);
select throws_ok('select * from public.customer_keep_fire(365)', 'P0001', 'Not enough permissions',
  'keep-or-fire is office-only');

select * from finish();
rollback;

-- Insurance loss ratio: premiums from the GL mirror vs claims from
-- safety_events, CPM against 12-month fleet miles, open-claim count.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

-- 12 months of $10k/mo insurance premium in the GL mirror
insert into public.gl_monthly (month, account, grp, amount)
select date_trunc('month', now()) - (interval '1 month' * g), 'Insurance - Truck', 'expense', 10000
from generate_series(0, 11) g;

-- claims: $30k closed + $6k open (recent), plus an old one outside the window
insert into public.safety_events (event_type, event_date, severity, claim_amount, status, description)
values ('accident', current_date - 100, 'major', 30000, 'closed', 't54'),
       ('accident', current_date - 20,  'minor', 6000,  'open',   't54'),
       ('accident', current_date - 500, 'major', 99000, 'closed', 't54-old');

-- 12k miles of delivered freight this year
insert into public.customers (company_name) values ('Ins Co');
insert into public.loads (load_number, customer_id, status, miles, empty_miles, delivery_time)
select 'INS-'||g, (select id from public.customers where company_name = 'Ins Co'),
       'delivered', 5000, 1000, now() - interval '30 days'
from generate_series(1, 2) g;

select is((public.insurance_snapshot()->>'premium_12m')::numeric, 120000::numeric,
  'premium sums the GL insurance accounts over 12 months');
select is((public.insurance_snapshot()->>'claims_12m')::numeric, 36000::numeric,
  'claims window excludes events older than 12 months');
select is((public.insurance_snapshot()->>'loss_ratio_pct')::numeric, 30.0::numeric,
  'loss ratio = 36k claims / 120k premium');
select is((public.insurance_snapshot()->>'insurance_cpm')::numeric, 10.0::numeric,
  'insurance CPM = premium / (loaded+empty) miles');
select is((public.insurance_snapshot()->>'open_claims')::int, 1,
  'open claim count only counts open events with a claim amount');

select * from finish();
rollback;

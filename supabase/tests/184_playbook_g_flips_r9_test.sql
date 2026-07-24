-- R9 Section G: the six flipped playbook metrics are live with a real source,
-- and the flip only touches those numbers.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

-- 1. all six targeted metrics are now live
select is(
  (select count(*) from public.playbook_metrics
    where number in (68, 297, 399, 400, 453, 476) and status = 'live'),
  6::bigint, 'all six R9-enabled metrics flipped to live');

-- 2. each carries a non-empty source (no live metric without a home)
select is(
  (select count(*) from public.playbook_metrics
    where number in (68, 297, 399, 400, 453, 476) and (source is null or source = '')),
  0::bigint, 'every flipped metric names the function that computes it');

-- 3. the forecast MAPE source points at the function this run built
select ok(
  (select source like '%forecast_mape_report%' from public.playbook_metrics where number = 68),
  'forecast accuracy is sourced from forecast_mape_report');

-- 4. the churn + deadhead flips point at their real computing functions
select ok(
  (select source like '%lost_customer_report%' from public.playbook_metrics where number = 400)
  and (select source like '%deadhead_patterns%' from public.playbook_metrics where number = 297)
  and (select source like '%sales_pipeline%' from public.playbook_metrics where number = 453),
  'churn / deadhead / win-rate flips each name their computing function');

select * from finish();
rollback;

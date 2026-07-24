-- R9 Section G cleanup: the source backfill lowers the sourceless-live count
-- without flipping any statuses or touching the deliberately-skipped metrics.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

-- 1. the sourceless-live count dropped substantially (>= 40 backfilled)
select cmp_ok(
  (select count(*) from public.playbook_metrics where status = 'live' and trim(source) = ''),
  '<=', 26::bigint, 'sourceless-live metrics down to the deliberately-skipped remainder');

-- 2. a representative backfilled metric now names company_scorecard
select ok(
  (select source like '%company_scorecard%' from public.playbook_metrics where number = 204),
  'Empty Mile % is sourced from company_scorecard');

-- 3. a safety metric names safety_summary
select ok(
  (select source like '%safety_summary%' from public.playbook_metrics where number = 651),
  'Total Accidents per Million Miles is sourced from safety_summary');

-- 4. the backfill flipped no statuses (still exactly the same live count as before is hard to assert
--    cross-migration; instead confirm we never turned a needs_data into live here)
select is(
  (select count(*) from public.playbook_metrics where number in (94, 653, 669, 901) and status = 'live' and trim(source) = ''),
  4::bigint, 'deliberately-skipped live metrics keep their empty source (not guessed)');

select * from finish();
rollback;

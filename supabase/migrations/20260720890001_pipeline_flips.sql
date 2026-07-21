-- R4 — quote capture went live (mining every 2h into quote_requests), so the
-- win-rate instruments flip on the same precedent as driver NPS: the capture
-- exists and sales_pipeline() computes; values populate as quote volume
-- arrives. Everything else in the needs_data sweep stays honest-red (tax
-- rates, budgets, or override tracking we don't have).
update public.playbook_metrics
   set status = 'live',
       source = 'sales_pipeline(start,end) — quote mining live since 2026-07-21, awaiting quote volume'
 where number in (393, 416) and status = 'needs_data';

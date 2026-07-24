-- R9 Section G cleanup: 66 playbook metrics were flipped to live in earlier
-- work but never got a `source` string — a live metric should always name the
-- function that computes it. company_scorecard() and safety_summary()
-- demonstrably compute the bulk of them; this backfills those honestly.
-- Concentration/injury/HOS-per-million/payroll-uptime are deliberately left
-- untouched — no single function clearly computes them, and a guessed source
-- would be worse than an empty one.

-- ── company_scorecard(): the omnibus operational/financial scorecard ──
update public.playbook_metrics set source = 'company_scorecard() operating_ratio_pct — total cost ÷ revenue', updated_at = now()
  where number in (1, 2, 103) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() revenue_per_total_mile', updated_at = now()
  where number in (19, 120) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() revenue_per_loaded_mile', updated_at = now()
  where number in (20, 121) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() cost_per_total_mile (all-in)', updated_at = now()
  where number in (23, 124) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() contribution_margin (revenue − variable) per load/mile', updated_at = now()
  where number in (34, 35, 135, 136) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() dso_days — AR ÷ 90-day billed × 90', updated_at = now()
  where number in (39, 140) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() bad_debt_pct — voided ÷ billed', updated_at = now()
  where number in (44, 145) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() invoice_cycle_days — delivery to invoice', updated_at = now()
  where number in (74, 175) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() empty_mile_pct — empty ÷ total miles', updated_at = now()
  where number in (204, 295) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() loaded_ratio_pct — loaded ÷ total miles', updated_at = now()
  where number in (205, 296) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() miles_per_tractor_per_week', updated_at = now()
  where number in (207, 298) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() loads_per_tractor_per_week', updated_at = now()
  where number in (210, 301) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() avg_length_of_haul — loaded miles ÷ loads', updated_at = now()
  where number in (211, 302) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() trailer_to_tractor_ratio', updated_at = now()
  where number in (231, 322) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() avg_tractor_age_years — from truck model year', updated_at = now()
  where number in (806, 868) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() avg_trailer_age_years — from trailer model year', updated_at = now()
  where number in (807, 869) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() driver_oos_rate_pct — driver out-of-service inspections', updated_at = now()
  where number in (665, 743) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() vehicle_oos_rate_pct — vehicle out-of-service inspections', updated_at = now()
  where number in (666, 744) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() preventable_accidents_in_window — count of preventable accidents', updated_at = now()
  where number in (652, 730) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'company_scorecard() new_logo_revenue_pct — revenue from first-time customers', updated_at = now()
  where number in (398, 458) and status = 'live' and trim(source) = '';

-- ── safety_summary(): the per-million-mile safety rates ──
update public.playbook_metrics set source = 'safety_summary() accidents_per_million_miles', updated_at = now()
  where number in (651, 729) and status = 'live' and trim(source) = '';
update public.playbook_metrics set source = 'safety_summary() preventable_per_million_miles', updated_at = now()
  where number in (650, 728) and status = 'live' and trim(source) = '';

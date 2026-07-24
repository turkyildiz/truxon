-- R9 Section G — playbook flips the R9 run's new capability now makes honest.
-- Each metric moves needs_data → live only because a real function computes it
-- today; single-terminal "Best/Worst Terminal" variants collapse to the fleet
-- value (the accepted pattern here — one region, so best = worst = fleet).
update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'forecast_mape_report() — earliest weekly revenue prediction vs realized revenue over matured weeks; snapshots banked Mondays, MAPE accrues as weeks close'
where number = 68 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'deadhead_patterns() avg_deadhead_miles — GPS/booked empty miles from delivery to next pickup; single terminal, so best-terminal = fleet'
where number = 297 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'lost_customer_report() — trailing revenue of customers quiet past 2x their own cadence; the revenue that stopped = revenue lost to churn'
where number = 400 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'segment_economics() fleet.customer_churn_pct — accounts active the prior equal window that then vanished'
where number = 399 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'sales_pipeline() win_rate_pct — won ÷ decided quote requests; the quote-pricing capture (quoted_rate/won/lost) sharpens the priced side'
where number = 453 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'sales_pipeline() win_rate_pct — awards ÷ decided quotes; single terminal, so best-terminal = fleet'
where number = 476 and status <> 'live';

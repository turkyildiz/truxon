-- Northstar night: flip playbook metrics needs_data/external → live now that the
-- data actually flows. Only BASE metrics that a real function computes today are
-- flipped (their WoW/segment/terminal derivatives still need trend infra and stay
-- needs_data). Each records the source it's computed from. Honest omissions:
-- avg dwell across ALL stops (229/230) isn't surfaced yet (detention_events only
-- returns over-free-time stops); DSCR/Debt-Equity stay gaps (GL mirror has no
-- debt/equity lines).
update public.playbook_metrics as m set status='live', source=v.src, updated_at=now()
from (values
  -- fleet cost basis (per-mile economics)
  (25, 'fleet_cost_basis.fixed_per_mile'),
  (26, 'fleet_cost_basis.pay_per_mile'),
  (27, 'company_scorecard.financial.fuel_cost_per_mile'),
  (29, 'company_scorecard.maintenance.maintenance_cost_per_mile'),
  (32, 'fleet_cost_basis.toll_per_mile'),
  -- headline financials from the scorecard
  (11, 'company_scorecard.financial.revenue'),
  -- balance-sheet / working capital from the QBO GL mirror
  (9,  'gl_cfo_snapshot.cash'),
  (45, 'gl_cfo_snapshot.dpo'),
  (47, 'gl_cfo_snapshot.working_capital'),
  (54, 'gl_cfo_snapshot.current_ratio'),
  -- billing
  (76, 'acct_unbilled_loads'),
  -- operations lit up by ELD + geocoding
  (213, 'company_scorecard.operations.on_time_delivery_pct'),
  (226, 'detention_events (hours ÷ loads)'),
  (227, 'detention_events (loads with detention ÷ loads)'),
  (259, 'company_scorecard.operations.fleet_mpg'),
  -- FMCSA CSA BASIC percentiles (feed now present → external becomes live)
  (658, 'safety_csa.unsafe_driving'),
  (659, 'safety_csa.crash'),
  (660, 'safety_csa.hos'),
  (661, 'safety_csa.vehicle_maint'),
  (662, 'safety_csa.controlled_substances'),
  (663, 'safety_csa.driver_fitness'),
  (664, 'safety_csa.hazmat')
) as v(number, src)
where m.number = v.number and m.status <> 'live';

-- R12 #2 — Playbook march: segment economics + honest metric flips.
-- New segment_economics() (per-truck / per-driver / per-customer money view,
-- margins anchored to the GL all-in cost per mile), quick ratio on the balance
-- mirror, wider nightly snapshot coverage (maintenance CPM, safety, segments,
-- AR>60), and 12 playbook flips with real computes behind them. Compound
-- metrics whose extra dimension we don't capture (worst-terminal, peer
-- benchmark, action plans) are deliberately NOT flipped.

-- ── segment_economics ───────────────────────────────────────────────────────
create or replace function public.segment_economics(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  weeks numeric := greatest(extract(epoch from (p_end - p_start)) / 86400.0 / 7.0, 0.1);
  v_fcb jsonb; v_gl_rpm numeric; v_var_cpm numeric;
  v_trucks int; v_drivers int; v_ebitda numeric;
  v_revenue numeric; v_below numeric; v_multi numeric;
  v_prior_customers int; v_lost int;
  v_truck jsonb; v_driver jsonb; v_cust jsonb; v_gap numeric;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  v_fcb := public.fleet_cost_basis();
  v_gl_rpm := coalesce((v_fcb->>'gl_all_in_rpm')::numeric, (v_fcb->>'breakeven_rpm')::numeric, 0);
  v_var_cpm := coalesce((v_fcb->>'fuel_price')::numeric / nullif((v_fcb->>'mpg')::numeric, 0), 0)
             + coalesce((v_fcb->>'pay_per_mile')::numeric, 0);
  select count(*) into v_trucks from trucks where status <> 'retired';
  select count(*) into v_drivers from drivers where status = 'active';
  v_ebitda := (public.gl_balance_ratios()->>'ebitda_12m')::numeric;

  select coalesce(sum(rate), 0) into v_revenue from loads
   where status in ('completed', 'billed') and delivery_time >= p_start and delivery_time < p_end;

  -- % of revenue booked below VARIABLE cost (fuel + driver pay per mile)
  select case when sum(rate) > 0
              then round(sum(rate) filter (where miles > 0 and rate / miles < v_var_cpm) / sum(rate) * 100, 1) end
    into v_below from loads
   where status in ('completed', 'billed') and delivery_time >= p_start and delivery_time < p_end;

  -- multi-stop share: loads with more than pickup+delivery
  select case when count(*) > 0
              then round(count(*) filter (where stops > 2)::numeric / count(*) * 100, 1) end
    into v_multi
    from (select l.id, count(s.load_id) stops
            from loads l left join load_stops s on s.load_id = l.id
           where l.status in ('completed', 'billed') and l.delivery_time >= p_start and l.delivery_time < p_end
           group by l.id) t;

  -- account churn: customers active the PRIOR equal window who vanished
  select count(*), count(*) filter (where not exists (
           select 1 from loads l2 where l2.customer_id = p.customer_id
            and l2.status in ('completed', 'billed')
            and l2.delivery_time >= p_start and l2.delivery_time < p_end))
    into v_prior_customers, v_lost
    from (select distinct customer_id from loads
           where status in ('completed', 'billed')
             and delivery_time >= p_start - (p_end - p_start) and delivery_time < p_start
             and customer_id is not null) p;

  select jsonb_agg(t order by t.revenue desc) into v_truck from (
    select tr.unit_number as unit, count(*) loads,
           sum(l.miles + coalesce(l.empty_miles, 0)) total_miles,
           round(sum(l.rate), 2) revenue,
           case when sum(l.miles) > 0 then round(sum(l.rate) / sum(l.miles), 2) end rpm,
           round(sum(l.rate) / weeks, 2) revenue_per_week
      from loads l join trucks tr on tr.id = l.truck_id
     where l.status in ('completed', 'billed') and l.delivery_time >= p_start and l.delivery_time < p_end
     group by tr.unit_number) t;

  select jsonb_agg(t order by t.revenue desc) into v_driver from (
    select d.full_name as driver, count(*) loads,
           sum(l.miles + coalesce(l.empty_miles, 0)) total_miles,
           round(sum(l.rate), 2) revenue,
           round(sum(l.rate) / weeks, 2) revenue_per_week,
           round(sum(l.miles * d.pay_per_mile
                 + case when d.empty_miles_paid then coalesce(l.empty_miles, 0) * d.pay_per_empty_mile else 0 end), 2) est_pay
      from loads l join drivers d on d.id = l.driver_id
     where l.status in ('completed', 'billed') and l.delivery_time >= p_start and l.delivery_time < p_end
     group by d.full_name) t;

  -- per-customer margin at the BOOKS' all-in cost per total mile
  select jsonb_agg(t order by t.revenue desc) into v_cust from (
    select c.company_name as customer, count(*) loads,
           round(sum(l.rate), 2) revenue,
           case when sum(l.miles) > 0 then round(sum(l.rate) / sum(l.miles), 2) end rpm,
           round(sum(l.rate) - sum(l.miles + coalesce(l.empty_miles, 0)) * v_gl_rpm, 2) est_margin,
           case when sum(l.rate) > 0
                then round((sum(l.rate) - sum(l.miles + coalesce(l.empty_miles, 0)) * v_gl_rpm) / sum(l.rate) * 100, 1) end margin_pct
      from loads l join customers c on c.id = l.customer_id
     where l.status in ('completed', 'billed') and l.delivery_time >= p_start and l.delivery_time < p_end
     group by c.company_name) t;

  -- top-quartile margin% minus fleet average margin%
  select round(avg(mp) filter (where q = 1) - avg(mp), 1) into v_gap from (
    select (e->>'margin_pct')::numeric mp, ntile(4) over (order by (e->>'margin_pct')::numeric desc) q
      from jsonb_array_elements(coalesce(v_cust, '[]'::jsonb)) e
     where e->>'margin_pct' is not null) t;

  return jsonb_build_object(
    'window', jsonb_build_object('start', p_start, 'end', p_end),
    'fleet', jsonb_build_object(
      'revenue', round(v_revenue, 2),
      'revenue_per_tractor_per_week', case when v_trucks > 0 then round(v_revenue / v_trucks / weeks, 2) end,
      'revenue_per_driver_per_week', case when v_drivers > 0 then round(v_revenue / v_drivers / weeks, 2) end,
      'ebitda_per_tractor_12m', case when v_trucks > 0 and v_ebitda is not null then round(v_ebitda / v_trucks, 2) end,
      'pct_revenue_below_variable_cost', v_below,
      'multi_stop_load_pct', v_multi,
      'customer_churn_pct', case when v_prior_customers > 0 then round(v_lost::numeric / v_prior_customers * 100, 1) end,
      'margin_top_quartile_gap_pts', v_gap,
      'all_in_rpm_basis', v_gl_rpm),
    'by_truck', coalesce(v_truck, '[]'::jsonb),
    'by_driver', coalesce(v_driver, '[]'::jsonb),
    'by_customer', coalesce(v_cust, '[]'::jsonb));
end;
$$;
revoke all on function public.segment_economics(timestamptz, timestamptz) from public, anon;
grant execute on function public.segment_economics(timestamptz, timestamptz) to authenticated, service_role;

-- ── gl_balance_ratios: + quick ratio (reproduced WHOLE from 20260720490001) ──
create or replace function public.gl_balance_ratios()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_bs record;
  v_noi12 numeric;
  v_dep12 numeric;
  v_net12 numeric;
  v_debt numeric;
  v_ebitda numeric;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select * into v_bs from bs_snapshot order by as_of desc limit 1;
  if v_bs is null then
    return jsonb_build_object('available', false);
  end if;

  select
    coalesce(sum(amount) filter (where grp in ('income', 'other_income')), 0)
      - coalesce(sum(amount) filter (where grp in ('cogs', 'expense')), 0),
    coalesce(sum(amount) filter (where grp = 'expense' and account ~* 'depreciation|amortization'), 0),
    coalesce(sum(amount) filter (where grp in ('income', 'other_income')), 0)
      - coalesce(sum(amount) filter (where grp in ('cogs', 'expense', 'other_expense')), 0)
  into v_noi12, v_dep12, v_net12
  from gl_monthly
  where month >= date_trunc('month', now()) - interval '12 months';

  v_debt := coalesce(v_bs.total_liabilities, 0) - coalesce(v_bs.ap, 0);
  v_ebitda := v_noi12 + v_dep12;

  return jsonb_build_object(
    'available', true,
    'as_of', v_bs.as_of,
    'debt', round(v_debt, 2),
    'net_debt', round(v_debt - coalesce(v_bs.cash, 0), 2),
    'debt_to_equity', case when coalesce(v_bs.equity, 0) <> 0
                           then round(v_debt / v_bs.equity, 2) end,
    'leverage', case when coalesce(v_bs.equity, 0) <> 0
                     then round(coalesce(v_bs.total_assets, 0) / v_bs.equity, 2) end,
    'quick_ratio', case when coalesce(v_bs.current_liabilities, 0) <> 0
                        then round((coalesce(v_bs.cash, 0) + coalesce(v_bs.ar, 0)) / v_bs.current_liabilities, 2) end,
    'ebitda_12m', round(v_ebitda, 2),
    'net_debt_to_ebitda', case when v_ebitda > 0
                               then round((v_debt - coalesce(v_bs.cash, 0)) / v_ebitda, 2) end,
    'roe_12m_pct', case when coalesce(v_bs.equity, 0) <> 0
                        then round(v_net12 / v_bs.equity * 100, 1) end
  );
end;
$$;
revoke all on function public.gl_balance_ratios() from public, anon;
grant execute on function public.gl_balance_ratios() to authenticated, service_role;

-- ── capture: + maintenance CPM, safety, segments, AR>60 (WHOLE from 500001) ──
create or replace function public.capture_metric_snapshots()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_count int := 0;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  insert into metric_snapshots (metric_key, captured_on, value)
  select mf.metric_key, current_date, mf.value
  from (
    select * from public.metric_flatten('scorecard7',
      public.company_scorecard(now() - interval '7 days', now()))
    union all
    select * from public.metric_flatten('scorecard30',
      public.company_scorecard(now() - interval '30 days', now()))
    union all
    select * from public.metric_flatten('ops7',
      public.fleet_ops_extras(now() - interval '7 days', now()))
    union all
    select * from public.metric_flatten('costbasis', public.fleet_cost_basis())
    union all
    select * from public.metric_flatten('cfo', public.gl_cfo_snapshot())
    union all
    select * from public.metric_flatten('balance', public.gl_balance_ratios())
    union all
    select * from public.metric_flatten('insurance', public.insurance_snapshot())
    union all
    select * from public.metric_flatten('mx30',
      public.maintenance_cpm(now() - interval '30 days', now()))
    union all
    select * from public.metric_flatten('safety30',
      public.safety_summary(now() - interval '30 days', now()))
    union all
    select * from public.metric_flatten('segments30',
      public.segment_economics(now() - interval '30 days', now()) -> 'fleet')
    union all
    select 'ar.over_45', coalesce(sum(
             case when i.source = 'qbo' then coalesce(i.qbo_balance, 0)
                  else i.total - coalesce(p.paid, 0) end), 0)
    from invoices i
    left join lateral (
      select sum(ip.amount) paid from invoice_payments ip where ip.invoice_id = i.id
    ) p on true
    where i.status = 'sent' and i.invoice_date < now() - interval '45 days'
    union all
    select 'ar.over_60', coalesce(sum(
             case when i.source = 'qbo' then coalesce(i.qbo_balance, 0)
                  else i.total - coalesce(p.paid, 0) end), 0)
    from invoices i
    left join lateral (
      select sum(ip.amount) paid from invoice_payments ip where ip.invoice_id = i.id
    ) p on true
    where i.status = 'sent' and i.invoice_date < now() - interval '60 days'
  ) mf
  where mf.value is not null and abs(mf.value) < 1e13
  on conflict (metric_key, captured_on) do update set value = excluded.value;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.capture_metric_snapshots() from public, anon, authenticated;
grant execute on function public.capture_metric_snapshots() to service_role;

select public.capture_metric_snapshots();

-- ── honest flips (13) ───────────────────────────────────────────────────────
update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'segment_economics(start,end) fleet block'
where number in (21, 22, 101) and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'metric_trends(''mx30'') — tire CPM snapshotted nightly from maintenance_cpm()'
where number = 132 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'metric_trends(''ar.over_60'') — nightly outstanding-AR>60d series'
where number = 143 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'metric_trends(''balance.quick_ratio'') — bs_snapshot (cash+AR)/current liabilities, nightly'
where number = 156 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'metric_trends(''scorecard30.systems.invoice_cycle_days'')'
where number = 176 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'company_scorecard() revenue.avg_revenue_per_customer'
where number = 406 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'segment_economics(start,end) by_customer est_margin (GL all-in RPM basis)'
where number = 407 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'segment_economics() fleet.customer_churn_pct + metric_trends(''segments30'') — single-region fleet'
where number = 459 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'segment_economics() fleet.margin_top_quartile_gap_pts'
where number = 467 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'metric_trends(''safety30.inspections'') — safety_summary snapshotted nightly'
where number = 745 and status <> 'live';

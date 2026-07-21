-- Balance-sheet ratios from the QBO mirror (Northstar resurrection):
-- bs_snapshot already carries total assets / liabilities / equity nightly, and
-- gl_monthly has 18 months of P&L — that is enough for debt/equity, net debt,
-- net-debt/EBITDA and ROE. NOT flipped: DSCR / FCF-after-debt-service — those
-- need principal payments, which a P&L mirror does not see (stays needs_data
-- rather than fabricated).
--
-- Approximations, stated where the numbers surface:
--   debt        = total_liabilities − AP  (interest-bearing split not in mirror)
--   EBITDA(12m) = net operating income + depreciation/amortization add-back

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

-- fold into the nightly series so WoW/MoM/slope accrue automatically
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
    select 'ar.over_45', coalesce(sum(
             case when i.source = 'qbo' then coalesce(i.qbo_balance, 0)
                  else i.total - coalesce(p.paid, 0) end), 0)
    from invoices i
    left join lateral (
      select sum(ip.amount) paid from invoice_payments ip where ip.invoice_id = i.id
    ) p on true
    where i.status = 'sent' and i.invoice_date < now() - interval '45 days'
  ) mf
  where mf.value is not null and abs(mf.value) < 1e13
  on conflict (metric_key, captured_on) do update set value = excluded.value;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.capture_metric_snapshots() from public, anon, authenticated;
grant execute on function public.capture_metric_snapshots() to service_role;

-- refresh today's snapshot with the new balance.* series
select public.capture_metric_snapshots();

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'gl_balance_ratios() — bs_snapshot mirror; debt = total liabilities − AP (approximation, principal split not in mirror)'
where number in (
  51,   -- Net Debt
  52,   -- Net Debt / EBITDA (EBITDA = NOI + D&A add-back, 12m)
  53,   -- Debt / Equity
  64,   -- Return on Equity (net income 12m / equity)
  152   -- WoW Change in Net Debt (balance.net_debt nightly series)
) and status <> 'live';

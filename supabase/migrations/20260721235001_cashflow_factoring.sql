-- Cash-flow forecast, factoring-aware. The old money-in model landed EVERY
-- dollar at the broker's learned pay date (30-90d out), so the 8-week window
-- showed ~$0 in vs $25k/wk out (a fictional -$200k). Reality with Denim
-- factoring: ~the advance (observed ~94.6%) arrives within days of invoicing;
-- only the small reserve waits for the broker to pay the factor. Money-in now:
--   * open FACTORED invoices  -> their remaining balance IS the reserve; lands
--     at the broker's predicted pay week (unchanged).
--   * open NON-factored invoices -> full balance at broker-pay week (unchanged).
--   * delivered-but-unbilled loads -> split: ADVANCE (observed advance rate)
--     lands ~invoice+3d +2d funding; RESERVE ((1-rate)) at invoice+3+pay-lag.
--   * FUTURE hauling -> the old model charged 8 weeks of run-rate COSTS while
--     counting zero revenue from loads not yet hauled (structurally doomed
--     graph). Now each week from the 2nd onward also gets the trailing-8-week
--     revenue run-rate x advance rate (factored cash arrives ~a week after the
--     haul). The small run-rate reserve tail is left out (conservative).
-- The advance rate is measured from the factored population (advanced/total),
-- falling back to 0.90 when there's no history.
create or replace function public.cashflow_forecast(p_weeks int default 8)
returns table (
  week_start date, week_number int, week_label text,
  expected_in numeric, expected_out numeric, net numeric, cumulative_net numeric
)
language plpgsql security definer set search_path = public stable as $$
declare
  v_dso numeric;
  v_fuel_wk numeric;
  v_fixed_wk numeric;
  v_driver_wk numeric;
  v_toll_wk numeric;
  v_maint_wk numeric;
  v_out_wk numeric;
  v_adv_rate numeric;
  v_rev_wk numeric;
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(round(avg(cpp.avg_days), 1), 30) into v_dso from public.customer_pay_profile() cpp;

  -- observed factoring advance rate (advanced / total across factored invoices)
  select coalesce(
           round(sum(i.total - case when i.status = 'sent' then public.invoice_balance(i) else 0 end)
                 / nullif(sum(i.total), 0), 4),
           0.90)
    into v_adv_rate
    from public.invoices i where i.factored_at is not null;

  -- trailing 8-week (56-day) cost averages
  select coalesce(sum(coalesce(net_of_discount, amount)), 0) / 8.0 into v_fuel_wk
    from public.fuel_transactions
   where status <> 'Declined' and transaction_time > now() - interval '56 days';
  select coalesce(sum(l.miles * d.pay_per_mile), 0) / 8.0 into v_driver_wk
    from public.loads l join public.drivers d on d.id = l.driver_id
   where l.status in ('completed', 'billed') and l.delivery_time > now() - interval '56 days';
  select coalesce(sum(monthly_cost), 0) / 4.33 into v_fixed_wk
    from public.trucks where status <> 'retired';
  select coalesce(sum(t.toll_charge), 0) / 8.0 into v_toll_wk
    from public.toll_transactions t
   where coalesce(t.post_date_time, t.exit_date_time) > now() - interval '56 days';
  select coalesce(sum(m.cost), 0) / 8.0 into v_maint_wk
    from public.maintenance_records m
   where m.status = 'completed' and m.date_completed > current_date - 56;
  v_out_wk := round(coalesce(v_fuel_wk, 0) + coalesce(v_driver_wk, 0) + coalesce(v_fixed_wk, 0)
                    + coalesce(v_toll_wk, 0) + coalesce(v_maint_wk, 0), 2);

  -- trailing 8-week delivered-revenue run rate (mirrors the cost run rate)
  select coalesce(sum(l.rate), 0) / 8.0 into v_rev_wk
    from public.loads l
   where l.status in ('completed', 'billed') and l.delivery_time > now() - interval '56 days';

  return query
  with weeks as (
    select public.trux_week_start(current_date) + (g * 7) as ws
    from generate_series(0, greatest(p_weeks, 1) - 1) g
  ),
  prof as (select * from public.customer_pay_profile()),
  pay as (select p2.invoice_id, sum(p2.amount) as paid from public.invoice_payments p2 group by p2.invoice_id),
  -- open invoices at their OUTSTANDING amount (for factored ones that IS the
  -- reserve), landed at the broker's predicted pay week
  inv_in as (
    select public.trux_week_start(
             greatest(i.invoice_date::date + coalesce(p.avg_days, v_dso)::int, current_date)) as ws,
           sum(case when i.source = 'qbo' and i.qbo_balance is not null then i.qbo_balance
                    else i.total - coalesce(pay.paid, 0) end) as amt
      from public.invoices i
      left join prof p on p.customer_id = i.customer_id
      left join pay on pay.invoice_id = i.id
     where i.status = 'sent'
       and (case when i.source = 'qbo' and i.qbo_balance is not null then i.qbo_balance
                 else i.total - coalesce(pay.paid, 0) end) > 0
     group by 1
  ),
  -- delivered-but-unbilled loads: the factoring ADVANCE arrives days after
  -- invoicing (~3d to invoice + ~2d funding), the RESERVE at broker pay lag
  unbilled_in as (
    select ws, sum(amt) as amt from (
      select public.trux_week_start(greatest(l.delivery_time::date + 5, current_date)) as ws,
             l.rate * v_adv_rate as amt
        from public.loads l
       where l.status = 'completed' and l.invoice_id is null and l.delivery_time is not null
      union all
      select public.trux_week_start(
               greatest(l.delivery_time::date + 3 + coalesce(p.avg_days, v_dso)::int, current_date)) as ws,
             l.rate * (1 - v_adv_rate) as amt
        from public.loads l left join prof p on p.customer_id = l.customer_id
       where l.status = 'completed' and l.invoice_id is null and l.delivery_time is not null
    ) u group by 1
  )
  select w.ws,
         public.trux_week_number(w.ws),
         public.trux_week_label(w.ws),
         round(coalesce(ii.amt, 0) + coalesce(ui.amt, 0)
               -- future hauling run-rate x advance rate, from the 2nd week on
               -- (this week's cash from this week's loads is mostly next week's)
               + case when w.ws > public.trux_week_start(current_date)
                      then v_rev_wk * v_adv_rate else 0 end, 2) as expected_in,
         v_out_wk as expected_out,
         round(coalesce(ii.amt, 0) + coalesce(ui.amt, 0)
               + case when w.ws > public.trux_week_start(current_date)
                      then v_rev_wk * v_adv_rate else 0 end - v_out_wk, 2) as net,
         round(sum(coalesce(ii.amt, 0) + coalesce(ui.amt, 0)
               + case when w.ws > public.trux_week_start(current_date)
                      then v_rev_wk * v_adv_rate else 0 end - v_out_wk)
                 over (order by w.ws rows between unbounded preceding and current row), 2) as cumulative_net
  from weeks w
  left join inv_in ii on ii.ws = w.ws
  left join unbilled_in ui on ui.ws = w.ws
  order by w.ws;
end;
$$;
revoke all on function public.cashflow_forecast(int) from public, anon;
grant execute on function public.cashflow_forecast(int) to authenticated, service_role;

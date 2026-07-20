-- Honesty fix for the cash-flow forecast's money-OUT. The first cut counted only
-- fuel + driver pay + truck fixed cost, which understates real weekly burn and
-- paints cash flow too rosy. Add the two other recurring cash outflows we track:
-- tolls (toll_transactions) and maintenance/repair spend (maintenance_records),
-- both as trailing 8-week averages so a lumpy repair smooths into a run-rate.
-- Signature unchanged; only v_out_wk widens.
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
begin
  if public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(round(avg(cpp.avg_days), 1), 30) into v_dso from public.customer_pay_profile() cpp;

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

  return query
  with weeks as (
    select public.trux_week_start(current_date) + (g * 7) as ws
    from generate_series(0, greatest(p_weeks, 1) - 1) g
  ),
  prof as (select * from public.customer_pay_profile()),
  -- money IN from open invoices, landed in the week of their predicted pay date
  inv_in as (
    select public.trux_week_start(
             greatest(i.invoice_date::date + coalesce(p.avg_days, v_dso)::int, current_date)) as ws,
           sum(i.total) as amt
      from public.invoices i left join prof p on p.customer_id = i.customer_id
     where i.status = 'sent'
     group by 1
  ),
  -- money IN from delivered-but-unbilled loads (invoice ~3 days out, then pay lag)
  unbilled_in as (
    select public.trux_week_start(
             greatest(l.delivery_time::date + 3 + coalesce(p.avg_days, v_dso)::int, current_date)) as ws,
           sum(l.rate) as amt
      from public.loads l left join prof p on p.customer_id = l.customer_id
     where l.status = 'completed' and l.invoice_id is null and l.delivery_time is not null
     group by 1
  )
  select w.ws,
         public.trux_week_number(w.ws),
         public.trux_week_label(w.ws),
         round(coalesce(ii.amt, 0) + coalesce(ui.amt, 0), 2) as expected_in,
         v_out_wk as expected_out,
         round(coalesce(ii.amt, 0) + coalesce(ui.amt, 0) - v_out_wk, 2) as net,
         round(sum(coalesce(ii.amt, 0) + coalesce(ui.amt, 0) - v_out_wk)
                 over (order by w.ws rows between unbounded preceding and current row), 2) as cumulative_net
  from weeks w
  left join inv_in ii on ii.ws = w.ws
  left join unbilled_in ui on ui.ws = w.ws
  order by w.ws;
end;
$$;
revoke all on function public.cashflow_forecast(int) from public, anon;
grant execute on function public.cashflow_forecast(int) to authenticated;

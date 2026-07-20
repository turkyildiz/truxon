-- Northstar predictive layer, gear 1 (transparent stats — no ML, no cold-start).
-- Learns each broker's real pay behavior from history and projects money IN.
--   customer_pay_profile()  — avg days-to-pay per customer (trailing 12 mo)
--   slow_pay_risk()         — which OPEN invoices will land late, and how late
--   cashflow_forecast(wks)  — weekly expected in / out / net over the horizon
-- All bucket on the standard week (trux_week_start). Admin/accountant only.

-- Per-customer average days from invoice_date → paid_at (paid invoices, 12 mo).
create or replace function public.customer_pay_profile()
returns table (customer_id bigint, avg_days numeric, paid_count int)
language sql security definer set search_path = public stable as $$
  select i.customer_id,
         round(avg(extract(epoch from (i.paid_at - i.invoice_date)) / 86400.0)::numeric, 1),
         count(*)::int
  from public.invoices i
  where i.status = 'paid' and i.paid_at is not null
    and i.invoice_date > now() - interval '365 days'
  group by i.customer_id;
$$;
revoke all on function public.customer_pay_profile() from public, anon;

-- Open invoices ranked by predicted lateness. Predicted pay = invoice_date +
-- that customer's avg days (or the fleet-wide average when we have no history).
create or replace function public.slow_pay_risk()
returns table (
  invoice_id bigint, invoice_number text, customer text, customer_id bigint,
  total numeric, invoice_date timestamptz, due_date timestamptz,
  avg_days numeric, predicted_pay_date date, predicted_days_late int, risk text
)
language plpgsql security definer set search_path = public stable as $$
declare v_dso numeric;
begin
  if public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(round(avg(cpp.avg_days), 1), 30) into v_dso from public.customer_pay_profile() cpp;
  return query
  with prof as (select * from public.customer_pay_profile())
  select i.id, i.invoice_number, c.company_name, i.customer_id, i.total, i.invoice_date, i.due_date,
         coalesce(p.avg_days, v_dso) as ad,
         (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int) as ppd,
         greatest(0, (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int)
                     - coalesce(i.due_date::date, i.invoice_date::date + 30))::int as late,
         case
           when greatest(0, (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int)
                            - coalesce(i.due_date::date, i.invoice_date::date + 30)) > 15 then 'high'
           when (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int)
                    > coalesce(i.due_date::date, i.invoice_date::date + 30) then 'medium'
           else 'low'
         end as risk
  from public.invoices i
  join public.customers c on c.id = i.customer_id
  left join prof p on p.customer_id = i.customer_id
  where i.status = 'sent'
  order by late desc, i.total desc;
end;
$$;
revoke all on function public.slow_pay_risk() from public, anon;
grant execute on function public.slow_pay_risk() to authenticated;

-- Weekly cash-flow forecast. IN = open invoices projected by pay behavior +
-- delivered-but-unbilled loads (invoice ~3 days after delivery, then pay lag).
-- OUT = trailing 8-week averages of fuel + driver pay + weekly truck fixed cost.
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
  v_out_wk := round(coalesce(v_fuel_wk, 0) + coalesce(v_driver_wk, 0) + coalesce(v_fixed_wk, 0), 2);

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

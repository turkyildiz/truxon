-- Company scorecard — the computable subset of the Owner's Playbook's 100
-- metrics, in one tested call, grouped by the playbook's categories. Trux calls
-- this so its C-suite answers come from verified figures. Metrics that need
-- data Truxon doesn't capture yet (safety/CSA, telematics idle/harsh, budgets,
-- bids, detention, insurance) are DELIBERATELY absent — Trux reports those as
-- "not captured yet" rather than inventing them.
create or replace function public.company_scorecard(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  win_days numeric := greatest(extract(epoch from (p_end - p_start)) / 86400.0, 1);
  weeks numeric := greatest(win_days / 7.0, 0.1);
  revenue numeric; loaded_mi numeric; total_mi numeric; empty_mi numeric; loads_n int;
  fuel numeric; tolls numeric; driver_pay numeric; maint numeric; truck_fixed numeric;
  gal numeric; active_trucks int; trailers_n int;
  ar_out numeric; billed numeric; voided numeric;
  top5 numeric; customers_n int; newlogo numeric;
  avg_tractor_age numeric; avg_trailer_age numeric; inv_cycle numeric;
  total_cost numeric;
begin
  if public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(rate),0), coalesce(sum(miles),0), coalesce(sum(empty_miles),0), count(*)
    into revenue, loaded_mi, empty_mi, loads_n
    from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;
  total_mi := loaded_mi + empty_mi;

  select coalesce(sum(coalesce(net_of_discount,amount)),0), coalesce(sum(gallons),0) into fuel, gal
    from public.fuel_transactions where status <> 'Declined' and transaction_time >= p_start and transaction_time < p_end;
  select coalesce(sum(toll_charge),0) into tolls from public.toll_transactions
   where coalesce(post_date_time,exit_date_time) >= p_start and coalesce(post_date_time,exit_date_time) < p_end;
  select coalesce(sum(l.miles*d.pay_per_mile + case when d.empty_miles_paid then coalesce(l.empty_miles,0)*d.pay_per_empty_mile else 0 end),0)
    into driver_pay from public.loads l join public.drivers d on d.id=l.driver_id
   where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end;
  select coalesce(sum(cost),0) into maint from public.maintenance_records
   where date_completed >= p_start::date and date_completed < p_end::date;
  select coalesce(round(sum(monthly_cost)*(win_days/30.44),2),0), count(*) into truck_fixed, active_trucks
    from public.trucks where status <> 'retired';
  select count(*) into trailers_n from public.trailers where status <> 'retired';
  total_cost := fuel + tolls + driver_pay + maint + truck_fixed;

  -- AR / bad debt
  select coalesce(sum(total),0) into ar_out from public.invoices where status='sent';
  select coalesce(sum(total),0) into billed from public.invoices where status in ('sent','paid') and invoice_date >= p_start and invoice_date < p_end;
  select coalesce(sum(total),0) into voided from public.invoices where status='void' and invoice_date >= p_start and invoice_date < p_end;

  -- customer concentration + new-logo (customers created in last 12 months)
  select coalesce(sum(rev),0) from (
    select l.customer_id, sum(l.rate) rev from public.loads l
     where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end
     group by l.customer_id order by rev desc limit 5) t into top5;
  select count(distinct customer_id) into customers_n from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;
  select coalesce(sum(l.rate),0) into newlogo from public.loads l join public.customers c on c.id=l.customer_id
   where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end
     and c.id in (select id from public.customers where created_at > now() - interval '12 months');

  -- fleet age (from year if present) + invoice cycle time
  select round(avg(extract(year from now()) - year),1) into avg_tractor_age from public.trucks where status<>'retired' and year is not null;
  select round(avg(extract(year from now()) - year),1) into avg_trailer_age from public.trailers where status<>'retired' and year is not null;
  select round(avg(extract(epoch from (i.invoice_date - l.delivery_time))/86400.0),1) into inv_cycle
    from public.loads l join public.invoices i on i.id = l.invoice_id
   where l.delivery_time >= p_start and l.delivery_time < p_end and l.delivery_time is not null;

  return jsonb_build_object(
    'window', jsonb_build_object('start', p_start, 'end', p_end, 'days', round(win_days,1)),
    'financial', jsonb_build_object(
      'revenue', round(revenue,2),
      'total_cost', round(total_cost,2),
      'net', round(revenue-total_cost,2),
      'operating_ratio_pct', case when revenue>0 then round(total_cost/revenue*100,1) end,
      'net_margin_pct', case when revenue>0 then round((revenue-total_cost)/revenue*100,1) end,
      'contribution_margin', round(revenue-(fuel+tolls+driver_pay),2),
      'revenue_per_total_mile', case when total_mi>0 then round(revenue/total_mi,2) end,
      'revenue_per_loaded_mile', case when loaded_mi>0 then round(revenue/loaded_mi,2) end,
      'cost_per_total_mile', case when total_mi>0 then round(total_cost/total_mi,2) end,
      'fuel_cost_per_mile', case when total_mi>0 then round(fuel/total_mi,3) end,
      'maintenance_cost_per_mile', case when total_mi>0 then round(maint/total_mi,3) end,
      'driver_pay_pct_revenue', case when revenue>0 then round(driver_pay/revenue*100,1) end,
      'ar_outstanding', round(ar_out,2),
      'dso_days', case when revenue>0 then round(ar_out/(revenue/win_days),1) end,
      'bad_debt_pct', case when billed>0 then round(voided/billed*100,2) end),
    'operations', jsonb_build_object(
      'loads', loads_n,
      'total_miles', total_mi, 'loaded_miles', loaded_mi, 'empty_miles', empty_mi,
      'empty_mile_pct', case when total_mi>0 then round(empty_mi/total_mi*100,1) end,
      'loaded_ratio_pct', case when total_mi>0 then round(loaded_mi/total_mi*100,1) end,
      'miles_per_tractor_per_week', case when active_trucks>0 then round(total_mi/active_trucks/weeks,0) end,
      'loads_per_tractor_per_week', case when active_trucks>0 then round(loads_n::numeric/active_trucks/weeks,2) end,
      'avg_length_of_haul', case when loads_n>0 then round(loaded_mi/loads_n,0) end,
      'trailer_to_tractor_ratio', case when active_trucks>0 then round(trailers_n::numeric/active_trucks,2) end,
      'fleet_mpg', case when gal>0 then round(loaded_mi/gal,2) end),
    'revenue', jsonb_build_object(
      'active_customers', customers_n,
      'avg_revenue_per_customer', case when customers_n>0 then round(revenue/customers_n,2) end,
      'top5_concentration_pct', case when revenue>0 then round(top5/revenue*100,1) end,
      'new_logo_revenue_pct', case when revenue>0 then round(newlogo/revenue*100,1) end,
      'rate_per_loaded_mile', case when loaded_mi>0 then round(revenue/loaded_mi,2) end),
    'maintenance', jsonb_build_object(
      'avg_tractor_age_years', avg_tractor_age,
      'avg_trailer_age_years', avg_trailer_age,
      'maintenance_cost_per_mile', case when total_mi>0 then round(maint/total_mi,3) end),
    'systems', jsonb_build_object(
      'invoice_cycle_days', inv_cycle),
    'not_captured', jsonb_build_array(
      'safety/CSA/HOS/accidents', 'telematics idle & harsh events', 'on-time pickup/delivery (no actual delivery timestamp)',
      'detention hours', 'budget vs actual', 'driver turnover/NPS', 'bids/win-rate/pipeline', 'insurance loss ratio', 'DSCR/leverage')
  );
end;
$$;

revoke execute on function public.company_scorecard(timestamptz, timestamptz) from public, anon;
grant execute on function public.company_scorecard(timestamptz, timestamptz) to authenticated;

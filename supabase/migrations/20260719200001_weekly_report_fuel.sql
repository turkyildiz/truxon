-- Fuel is ~1/3 of operating cost, so it belongs in the weekly P&L, not just on
-- a transactions page. weekly_report now carries per-truck fuel cost, gallons,
-- MPG (loaded miles / gallons), and net-after-fuel, plus fuel in the totals
-- (with fuel as a % of revenue). Fuel is matched to a truck by the importer;
-- truck-level rows use that truck's fuel in the week, while the totals use ALL
-- fuel spend in the week (matched or not) so nothing is lost from the P&L.

create or replace function public.weekly_report(p_week_of date default current_date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := p_week_of - ((extract(isodow from p_week_of))::int - 1);
  wk_end date := wk_start + 6;
  wk_from timestamptz := wk_start::timestamptz;
  wk_to timestamptz := (wk_end + 1)::timestamptz;
  result jsonb;
begin
  if public.my_role() is null or public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  with wk_loads as (
    select l.* from public.loads l
     where l.status in ('completed', 'billed')
       and l.delivery_time >= wk_from
       and l.delivery_time < wk_to
  ),
  fuel_wk as (
    select f.truck_id,
           sum(coalesce(f.net_of_discount, f.amount)) as fuel_cost,
           coalesce(sum(f.gallons), 0) as fuel_gallons
      from public.fuel_transactions f
     where f.truck_id is not null
       and f.status <> 'Declined'
       and f.transaction_time >= wk_from
       and f.transaction_time < wk_to
     group by f.truck_id
  ),
  by_truck as (
    select t.id as key_id, t.unit_number as name,
           count(*)::int as loads, sum(w.miles) as miles, sum(w.rate) as revenue,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile,
           round(coalesce(fw.fuel_cost, 0), 2) as fuel_cost,
           coalesce(fw.fuel_gallons, 0) as fuel_gallons,
           case when coalesce(fw.fuel_gallons, 0) > 0 then round(sum(w.miles) / fw.fuel_gallons, 2) end as mpg,
           round(sum(w.rate) - coalesce(fw.fuel_cost, 0), 2) as net_after_fuel
      from wk_loads w
      join public.trucks t on t.id = w.truck_id
      left join fuel_wk fw on fw.truck_id = t.id
     group by t.id, t.unit_number, fw.fuel_cost, fw.fuel_gallons
  ),
  by_driver as (
    select d.id as key_id, d.full_name as name,
           count(*)::int as loads, sum(w.miles) as miles, sum(w.rate) as revenue,
           sum(w.empty_miles) as empty_miles,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile,
           round(sum(w.miles) * d.pay_per_mile
                 + case when d.empty_miles_paid then coalesce(sum(w.empty_miles), 0) * d.pay_per_empty_mile else 0 end,
             2) as driver_pay
      from wk_loads w join public.drivers d on d.id = w.driver_id
     group by d.id, d.full_name, d.pay_per_mile, d.pay_per_empty_mile, d.empty_miles_paid
  ),
  -- All fuel spend in the week (including transactions not matched to a truck),
  -- so the company-level P&L total is complete.
  fuel_total as (
    select coalesce(sum(coalesce(net_of_discount, amount)), 0) as fuel_cost,
           coalesce(sum(gallons), 0) as fuel_gallons
      from public.fuel_transactions
     where status <> 'Declined' and transaction_time >= wk_from and transaction_time < wk_to
  )
  select jsonb_build_object(
    'week_start', wk_start,
    'week_end', wk_end,
    'by_truck', coalesce((select jsonb_agg(to_jsonb(bt) order by bt.revenue desc) from by_truck bt), '[]'::jsonb),
    'by_driver', coalesce((select jsonb_agg(to_jsonb(bd) order by bd.revenue desc) from by_driver bd), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'loads', count(*)::int,
        'miles', coalesce(sum(w.miles), 0),
        'revenue', coalesce(sum(w.rate), 0),
        'avg_rate_per_mile', case when coalesce(sum(w.miles), 0) > 0 then round(sum(w.rate) / sum(w.miles), 2) end,
        'fuel_cost', (select round(fuel_cost, 2) from fuel_total),
        'fuel_gallons', (select fuel_gallons from fuel_total),
        'net_after_fuel', round(coalesce(sum(w.rate), 0) - (select fuel_cost from fuel_total), 2),
        'fuel_pct_of_revenue', case when coalesce(sum(w.rate), 0) > 0
          then round((select fuel_cost from fuel_total) / sum(w.rate) * 100, 1) end
      ) from wk_loads w)
  ) into result;
  return result;
end;
$$;

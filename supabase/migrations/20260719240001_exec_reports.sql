-- Executive analytics for the Trux "C-suite" page. These are deterministic,
-- pgTAP-tested report functions so Trux answers CFO/COO questions with numbers
-- that are correct by construction, instead of free-hand LLM SQL. Trux calls
-- them (SELECT * FROM ...) via its read-only query tool; ad-hoc SQL stays for
-- open-ended exploration. All financial, so admin/accountant/dispatcher only.

-- ---------- Fuel efficiency by driver (the "who burns more fuel" report) ----------
-- Gallons/spend come from the fuel card (fuel_transactions.driver_id, matched
-- from AtoB's Driver Name); miles from completed/billed loads for that driver
-- in the window. MPG = miles / gallons. Worst MPG first so heavy users surface.
create or replace function public.fuel_efficiency(p_start timestamptz, p_end timestamptz)
returns table (
  driver_id bigint, driver_name text, loads int, miles numeric,
  gallons numeric, mpg numeric, fuel_spend numeric, fuel_cost_per_mile numeric
)
language sql stable security definer set search_path = public
as $$
  with fuel as (
    select f.driver_id,
           sum(f.gallons) as gallons,
           sum(coalesce(f.net_of_discount, f.amount)) as spend
      from public.fuel_transactions f
     where f.driver_id is not null and f.status <> 'Declined'
       and f.transaction_time >= p_start and f.transaction_time < p_end
     group by f.driver_id
  ),
  miles as (
    select l.driver_id, count(*)::int as loads, sum(l.miles) as miles
      from public.loads l
     where l.driver_id is not null and l.status in ('completed','billed')
       and l.delivery_time >= p_start and l.delivery_time < p_end
     group by l.driver_id
  )
  select d.id, d.full_name,
         coalesce(m.loads,0), coalesce(m.miles,0),
         coalesce(f.gallons,0),
         case when coalesce(f.gallons,0) > 0 then round(coalesce(m.miles,0) / f.gallons, 2) end,
         round(coalesce(f.spend,0),2),
         case when coalesce(m.miles,0) > 0 then round(coalesce(f.spend,0) / m.miles, 3) end
    from public.drivers d
    join fuel f on f.driver_id = d.id           -- only drivers with fuel activity
    left join miles m on m.driver_id = d.id
   where public.my_role() in ('admin','accountant','dispatcher')
   order by 6 nulls last;                         -- mpg ascending (worst first)
$$;

-- ---------- AR aging (who owes us money) ----------
-- Outstanding = sent invoices (draft not yet billed; paid/void excluded), aged
-- from due_date (or invoice_date) into standard 30-day buckets, per customer.
create or replace function public.ar_aging()
returns table (
  customer_id bigint, company_name text, invoices int, outstanding numeric,
  d0_30 numeric, d31_60 numeric, d61_90 numeric, d90_plus numeric
)
language sql stable security definer set search_path = public
as $$
  with aged as (
    select i.customer_id, i.total,
           (now()::date - coalesce(i.due_date, i.invoice_date)::date) as age_days
      from public.invoices i
     where i.status = 'sent'
  )
  select c.id, c.company_name, count(*)::int, sum(a.total),
         sum(a.total) filter (where a.age_days <= 30),
         sum(a.total) filter (where a.age_days between 31 and 60),
         sum(a.total) filter (where a.age_days between 61 and 90),
         sum(a.total) filter (where a.age_days > 90)
    from aged a join public.customers c on c.id = a.customer_id
   where public.my_role() in ('admin','accountant','dispatcher')
   group by c.id, c.company_name
   order by 4 desc;                               -- most outstanding first
$$;

-- ---------- Company P&L summary over a window ----------
-- Revenue (completed/billed loads) minus the big cost lines: fuel, tolls,
-- driver pay (same formula as weekly_report), maintenance, and truck fixed
-- cost prorated to the window. One jsonb object with the figures + net margin.
create or replace function public.pnl_summary(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  win_days numeric := greatest(extract(epoch from (p_end - p_start)) / 86400.0, 0);
  revenue numeric;
  fuel_cost numeric;
  toll_cost numeric;
  driver_pay numeric;
  maint_cost numeric;
  truck_fixed numeric;
begin
  if public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(rate),0) into revenue from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;

  select coalesce(sum(coalesce(net_of_discount, amount)),0) into fuel_cost from public.fuel_transactions
   where status <> 'Declined' and transaction_time >= p_start and transaction_time < p_end;

  select coalesce(sum(toll_charge),0) into toll_cost from public.toll_transactions
   where coalesce(post_date_time, exit_date_time) >= p_start and coalesce(post_date_time, exit_date_time) < p_end;

  select coalesce(sum(l.miles * d.pay_per_mile
           + case when d.empty_miles_paid then coalesce(l.empty_miles,0) * d.pay_per_empty_mile else 0 end), 0)
    into driver_pay
    from public.loads l join public.drivers d on d.id = l.driver_id
   where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end;

  select coalesce(sum(cost),0) into maint_cost from public.maintenance_records
   where date_completed >= p_start::date and date_completed < p_end::date;

  -- Monthly truck cost prorated to the window length.
  select coalesce(round(sum(monthly_cost) * (win_days / 30.44), 2), 0) into truck_fixed
    from public.trucks where status <> 'retired';

  return jsonb_build_object(
    'window_start', p_start, 'window_end', p_end,
    'revenue', round(revenue,2),
    'fuel_cost', round(fuel_cost,2),
    'toll_cost', round(toll_cost,2),
    'driver_pay', round(driver_pay,2),
    'maintenance_cost', round(maint_cost,2),
    'truck_fixed_cost', truck_fixed,
    'total_cost', round(fuel_cost + toll_cost + driver_pay + maint_cost + truck_fixed, 2),
    'net', round(revenue - (fuel_cost + toll_cost + driver_pay + maint_cost + truck_fixed), 2),
    'net_margin_pct', case when revenue > 0
      then round((revenue - (fuel_cost + toll_cost + driver_pay + maint_cost + truck_fixed)) / revenue * 100, 1) end
  );
end;
$$;

revoke execute on function public.fuel_efficiency(timestamptz, timestamptz) from public, anon;
revoke execute on function public.ar_aging() from public, anon;
revoke execute on function public.pnl_summary(timestamptz, timestamptz) from public, anon;
grant execute on function public.fuel_efficiency(timestamptz, timestamptz) to authenticated;
grant execute on function public.ar_aging() to authenticated;
grant execute on function public.pnl_summary(timestamptz, timestamptz) to authenticated;

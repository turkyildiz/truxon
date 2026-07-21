-- R3 #6 — load profitability actuals: what each completed load ACTUALLY made
-- vs the booking estimate. Closes the loop on the margin panel.
--
-- Model (stated): driver pay from the driver's real per-mile rates; tolls are
-- the truck's transponder charges inside the load window; actual fuel = the
-- truck's BANKED ELD miles in the window (deadhead and reroutes included)
-- x the fleet's GL fuel cost per mile. Fixed costs excluded on both sides —
-- this compares variable margin like-for-like.
create function public.load_actuals(p_days int default 60)
returns table (
  load_id bigint,
  load_number text,
  customer text,
  delivered_on date,
  rate numeric,
  miles numeric,
  eld_miles numeric,
  driver_pay numeric,
  est_fuel numeric,
  actual_fuel numeric,
  tolls numeric,
  est_margin numeric,
  actual_margin numeric,
  variance numeric
)
language plpgsql security definer set search_path = public stable
as $$
declare
  v_fuel_cpm numeric := coalesce(((public.fleet_cost_basis())->>'fuel_cost_per_mile')::numeric, 0);
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return query
  select l.id, l.load_number, c.company_name,
         l.delivery_time::date,
         l.rate, l.miles,
         em.mi,
         pay.amt,
         round(l.miles * v_fuel_cpm, 2),
         round(coalesce(em.mi, l.miles) * v_fuel_cpm, 2),
         tl.amt,
         round(l.rate - pay.amt - l.miles * v_fuel_cpm, 2),
         round(l.rate - pay.amt - coalesce(em.mi, l.miles) * v_fuel_cpm - tl.amt, 2),
         round((l.rate - pay.amt - coalesce(em.mi, l.miles) * v_fuel_cpm - tl.amt)
               - (l.rate - pay.amt - l.miles * v_fuel_cpm), 2)
  from public.loads l
  join public.customers c on c.id = l.customer_id
  left join lateral (
    select coalesce(l.miles * d.pay_per_mile
             + case when d.empty_miles_paid then coalesce(l.empty_miles, 0) * d.pay_per_empty_mile else 0 end,
           0) as amt
      from public.drivers d where d.id = l.driver_id
  ) pay0 on true
  cross join lateral (select coalesce(pay0.amt, 0) as amt) pay
  left join lateral (
    select sum(e.miles) as mi
      from public.eld_daily_miles e
     where e.truck_id = l.truck_id
       and e.day between coalesce(l.pickup_time, l.delivery_time)::date and l.delivery_time::date
  ) em on true
  cross join lateral (
    select coalesce((select sum(t.toll_charge) from public.toll_transactions t
                      where t.truck_id = l.truck_id
                        and t.exit_date_time between coalesce(l.pickup_time, l.delivery_time - interval '2 days')
                                                 and l.delivery_time + interval '12 hours'), 0) as amt
  ) tl
  where l.status in ('completed', 'billed')
    and l.delivery_time >= now() - make_interval(days => p_days)
    and l.miles > 0
  order by l.delivery_time desc;
end;
$$;
revoke all on function public.load_actuals(int) from public, anon;
grant execute on function public.load_actuals(int) to authenticated, service_role;

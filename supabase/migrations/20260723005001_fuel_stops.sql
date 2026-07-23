-- R9 #49: fuel-stop analysis from our OWN purchase history — no rate feed
-- needed to find expensive habits. Per merchant stop: visits, gallons, the
-- price paid vs the same-state fleet average in the same window, and the
-- dollars that premium cost. External fuel-price feeds stay an honest
-- non-dependency; this measures behavior against ourselves.
create or replace function public.fuel_stop_analysis(p_days int default 60)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_rows jsonb; v_avg numeric;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  select round(avg(price_per_gallon), 3) into v_avg
    from fuel_transactions
   where transaction_time > now() - make_interval(days => p_days)
     and gallons > 0 and price_per_gallon > 0;

  with state_avg as (
    select merchant_state, avg(price_per_gallon) as st_avg
      from fuel_transactions
     where transaction_time > now() - make_interval(days => p_days)
       and gallons > 0 and price_per_gallon > 0
     group by merchant_state
  )
  select jsonb_agg(t order by t.premium_paid desc nulls last) into v_rows from (
    select f.merchant, f.merchant_city, f.merchant_state,
           count(*) as visits,
           round(sum(f.gallons), 0) as gallons,
           round(avg(f.price_per_gallon), 3) as avg_price,
           round(sa.st_avg, 3) as state_avg,
           round((avg(f.price_per_gallon) - sa.st_avg) * sum(f.gallons), 2) as premium_paid
      from fuel_transactions f
      join state_avg sa on sa.merchant_state = f.merchant_state
     where f.transaction_time > now() - make_interval(days => p_days)
       and f.gallons > 0 and f.price_per_gallon > 0
     group by f.merchant, f.merchant_city, f.merchant_state, sa.st_avg
    having count(*) >= 2) t;

  return jsonb_build_object(
    'days', p_days,
    'fleet_avg_price', v_avg,
    'stops', coalesce(v_rows, '[]'::jsonb),
    'note', 'premium vs our own same-state average in the window - behavior, not market rates',
    'as_of', now());
end;
$$;
revoke all on function public.fuel_stop_analysis(int) from public, anon;
grant execute on function public.fuel_stop_analysis(int) to authenticated, service_role;

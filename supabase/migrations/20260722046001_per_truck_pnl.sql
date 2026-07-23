-- R9 #42/#43: per-truck P&L + ROI ranking. Each unit judged on its own
-- ledger: revenue from its loads, minus its actual fuel/toll/maintenance
-- spend, estimated driver pay on its loads, and its equipment payment.
-- payments_entered says honestly whether the payment column means anything
-- yet (it's 0/12 until the owner fills the truck forms).
create or replace function public.per_truck_pnl(p_months int default 3)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_start timestamptz := date_trunc('month', now()) - make_interval(months => greatest(p_months, 1) - 1);
  v_rows jsonb;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select jsonb_agg(t order by t.net desc nulls last) into v_rows from (
    select tk.unit_number as unit,
           tk.ownership,
           coalesce(r.revenue, 0) as revenue,
           coalesce(r.loads, 0) as loads,
           coalesce(f.fuel, 0) as fuel,
           coalesce(tl.tolls, 0) as tolls,
           coalesce(mx.maint, 0) as maintenance,
           coalesce(r.driver_pay, 0) as driver_pay,
           round(coalesce(tk.monthly_payment, 0) * p_months, 2) as payment,
           round(coalesce(r.revenue, 0) - coalesce(f.fuel, 0) - coalesce(tl.tolls, 0)
                 - coalesce(mx.maint, 0) - coalesce(r.driver_pay, 0)
                 - coalesce(tk.monthly_payment, 0) * p_months, 2) as net,
           case when coalesce(tk.monthly_payment, 0) > 0
             then round((coalesce(r.revenue, 0) - coalesce(f.fuel, 0) - coalesce(tl.tolls, 0)
                         - coalesce(mx.maint, 0) - coalesce(r.driver_pay, 0))
                        / (tk.monthly_payment * p_months), 2) end as roi_x
      from trucks tk
      left join lateral (
        select round(sum(l.rate), 2) revenue, count(*) loads,
               round(sum(l.miles * coalesce(d.pay_per_mile, 0)
                 + case when d.empty_miles_paid then coalesce(l.empty_miles, 0) * d.pay_per_empty_mile else 0 end), 2) driver_pay
          from loads l left join drivers d on d.id = l.driver_id
         where l.truck_id = tk.id and l.status in ('completed','billed')
           and l.delivery_time >= v_start) r on true
      left join lateral (
        select round(sum(coalesce(ft.net_of_discount, ft.amount)), 2) fuel
          from fuel_transactions ft
         where ft.truck_id = tk.id and ft.transaction_time >= v_start) f on true
      left join lateral (
        select round(sum(tt.toll_charge), 2) tolls
          from toll_transactions tt
         where tt.truck_id = tk.id and tt.exit_date_time >= v_start) tl on true
      left join lateral (
        select round(sum(m.cost), 2) maint
          from maintenance_records m
         where m.truck_id = tk.id and m.status = 'completed' and m.date_completed >= v_start::date) mx on true
     where tk.status <> 'retired') t;

  return jsonb_build_object(
    'months', p_months,
    'payments_entered', (select count(*) from trucks where status <> 'retired' and coalesce(monthly_payment, 0) > 0),
    'trucks_total', (select count(*) from trucks where status <> 'retired'),
    'trucks', coalesce(v_rows, '[]'::jsonb),
    'as_of', now());
end;
$$;
revoke all on function public.per_truck_pnl(int) from public, anon;
grant execute on function public.per_truck_pnl(int) to authenticated, service_role;

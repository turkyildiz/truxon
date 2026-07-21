-- R3 #12 — booking exposure guard. Before dispatch books another load for a
-- customer, show what they already owe us in total float: open AR + unbilled
-- completed work + committed open loads. The limit rule is explicit:
--   limit = greatest(1.5 x their avg monthly billed (6m), $5,000),
--   HALVED when they average >90 days to pay (slow money is riskier money).
create function public.customer_exposure(p_customer_id bigint)
returns jsonb
language plpgsql security definer set search_path = public stable
as $$
declare
  v_ar numeric; v_unbilled numeric; v_open numeric;
  v_monthly numeric; v_days numeric; v_limit numeric; v_exposure numeric;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(public.invoice_balance(i)), 0) into v_ar
    from invoices i where i.customer_id = p_customer_id and i.status = 'sent';

  select coalesce(sum(l.rate), 0) into v_unbilled
    from loads l
   where l.customer_id = p_customer_id and l.status = 'completed' and l.invoice_id is null;

  select coalesce(sum(l.rate), 0) into v_open
    from loads l
   where l.customer_id = p_customer_id and l.status in ('pending', 'assigned', 'in_transit');

  select coalesce(sum(i.total), 0) / 6.0 into v_monthly
    from invoices i
   where i.customer_id = p_customer_id
     and i.status in ('sent', 'paid')
     and i.invoice_date >= now() - interval '6 months';

  select p.avg_days into v_days
    from public.customer_pay_profile() p where p.customer_id = p_customer_id;

  v_limit := greatest(1.5 * v_monthly, 5000);
  if coalesce(v_days, 0) > 90 then v_limit := v_limit / 2; end if;
  v_exposure := v_ar + v_unbilled + v_open;

  return jsonb_build_object(
    'open_ar', round(v_ar),
    'unbilled', round(v_unbilled),
    'open_loads', round(v_open),
    'exposure', round(v_exposure),
    'limit', round(v_limit),
    'avg_days_to_pay', v_days,
    'over_limit', v_exposure > v_limit,
    'rule', '1.5x avg monthly billed (6m), min $5k, halved when avg pay >90d');
end;
$$;
revoke all on function public.customer_exposure(bigint) from public, anon;
grant execute on function public.customer_exposure(bigint) to authenticated, service_role;

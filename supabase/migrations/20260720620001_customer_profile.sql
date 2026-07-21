-- R12 #5 — Customer detail: one RPC behind the "should I keep hauling for
-- these people" page. Volume/rate/margin trend by month, pay behavior on true
-- outstanding balances, open AR, open loads, detention, documents.
create or replace function public.customer_profile(p_customer_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_gl_rpm numeric;
  v_ident jsonb; v_totals jsonb; v_monthly jsonb; v_pay jsonb; v_open jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select to_jsonb(c) - 'created_at' into v_ident from customers c where c.id = p_customer_id;
  if v_ident is null then
    return jsonb_build_object('found', false);
  end if;

  v_gl_rpm := coalesce((public.fleet_cost_basis()->>'gl_all_in_rpm')::numeric,
                       (public.fleet_cost_basis()->>'breakeven_rpm')::numeric, 0);

  select jsonb_build_object(
      'loads_12m', count(*),
      'revenue_12m', round(coalesce(sum(rate), 0), 2),
      'rpm_12m', round(sum(rate) / nullif(sum(miles), 0), 2),
      'est_margin_12m', round(coalesce(sum(rate) - sum(miles + coalesce(empty_miles, 0)) * v_gl_rpm, 0), 2),
      'margin_pct_12m', round((sum(rate) - sum(miles + coalesce(empty_miles, 0)) * v_gl_rpm)
                              / nullif(sum(rate), 0) * 100, 1),
      'last_load', max(delivery_time)::date,
      'first_load', min(delivery_time)::date)
    into v_totals
    from loads
   where customer_id = p_customer_id and status in ('completed', 'billed')
     and delivery_time > now() - interval '12 months';

  select jsonb_agg(t order by t.month) into v_monthly from (
    select to_char(date_trunc('month', delivery_time), 'YYYY-MM') as month,
           count(*) as loads,
           round(sum(rate), 0) as revenue,
           round(sum(rate) / nullif(sum(miles), 0), 2) as rpm
      from loads
     where customer_id = p_customer_id and status in ('completed', 'billed')
       and delivery_time > now() - interval '12 months'
     group by 1) t;

  select jsonb_build_object(
      'avg_days_to_pay', (select p.avg_days from public.customer_pay_profile() p where p.customer_id = p_customer_id),
      'paid_invoices_12m', (select p.paid_count from public.customer_pay_profile() p where p.customer_id = p_customer_id),
      'open_outstanding', round(coalesce((
          select sum(public.invoice_balance(i)) from invoices i
           where i.customer_id = p_customer_id and i.status = 'sent'), 0), 2),
      'past_due_outstanding', round(coalesce((
          select sum(public.invoice_balance(i)) from invoices i
           where i.customer_id = p_customer_id and i.status = 'sent' and i.due_date < now()), 0), 2),
      'open_invoices', (select count(*) from invoices i
           where i.customer_id = p_customer_id and i.status = 'sent' and public.invoice_balance(i) > 0))
    into v_pay;

  select jsonb_build_object(
      'open_loads', (select count(*) from loads
           where customer_id = p_customer_id and status in ('pending', 'assigned', 'in_transit', 'delivered')),
      'unbilled_completed', (select count(*) from loads
           where customer_id = p_customer_id and status = 'completed' and invoice_id is null),
      'documents', (select count(*) from documents d
           where (d.entity_type = 'customer' and d.entity_id = p_customer_id)
              or (d.entity_type = 'load' and d.entity_id in
                    (select id from loads where customer_id = p_customer_id))),
      'detention_hours_45d', round(coalesce((
          select sum(e.detention_min) from public.detention_events(45) e
           join loads l on l.id = e.load_id where l.customer_id = p_customer_id), 0) / 60.0, 1))
    into v_open;

  return jsonb_build_object(
    'found', true,
    'customer', v_ident,
    'all_in_rpm_basis', v_gl_rpm,
    'totals', v_totals,
    'monthly', coalesce(v_monthly, '[]'::jsonb),
    'pay', v_pay,
    'activity', v_open);
end;
$$;
revoke all on function public.customer_profile(bigint) from public, anon;
grant execute on function public.customer_profile(bigint) to authenticated, service_role;

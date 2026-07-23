-- R9 #32: factoring cost dashboard. What factoring actually costs: effective
-- rate (true Denim fees ÷ face), fees by month, and what it buys — days of
-- float vs the brokers' book pay speed — expressed as an annualized rate the
-- owner can compare to any other money.
create or replace function public.factoring_cost_summary()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_face numeric;
  v_fees numeric;
  v_rate numeric;
  v_book_days numeric;
  v_days_gained numeric;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','accountant') then
    raise exception 'Not enough permissions';
  end if;

  select round(sum(i.total), 2), round(sum(i.factoring_fee), 2)
    into v_face, v_fees
    from invoices i
   where i.factored_at is not null and coalesce(i.factoring_fee, 0) > 0 and i.total > 0;
  v_rate := round(v_fees / nullif(v_face, 0) * 100, 2);

  select round(avg(cpp.avg_days), 0) into v_book_days from public.customer_pay_profile() cpp;
  -- Denim advances land ~2 days after invoicing
  v_days_gained := greatest(coalesce(v_book_days, 0) - 2, 0);

  return jsonb_build_object(
    'face_total', coalesce(v_face, 0),
    'fees_total', coalesce(v_fees, 0),
    'effective_rate_pct', v_rate,
    'book_days_to_pay', v_book_days,
    'days_of_float_gained', v_days_gained,
    'annualized_cost_pct', case when v_days_gained > 0
      then round(v_rate / v_days_gained * 365, 1) end,
    'months', coalesce((select jsonb_agg(jsonb_build_object(
        'month', x.mo, 'invoices', x.n, 'face', x.face, 'fees', x.fees,
        'rate_pct', round(x.fees / nullif(x.face, 0) * 100, 2)) order by x.mo)
      from (select to_char(date_trunc('month', i.invoice_date), 'YYYY-MM') mo,
                   count(*) n, round(sum(i.total), 2) face,
                   round(sum(i.factoring_fee), 2) fees
              from invoices i
             where i.factored_at is not null and coalesce(i.factoring_fee, 0) > 0 and i.total > 0
             group by 1) x), '[]'::jsonb),
    'as_of', now());
end;
$$;
revoke all on function public.factoring_cost_summary() from public, anon;
grant execute on function public.factoring_cost_summary() to authenticated, service_role;

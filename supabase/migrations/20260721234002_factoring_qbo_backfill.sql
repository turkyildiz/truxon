-- The factored/short-paid invoices are QBO-sourced (reserve lives in qbo_balance,
-- no invoice_payments row), so the first backfill (Truxon-native only) caught none.
-- Here: (1) compute "advanced" as total − current balance so it works for QBO too,
-- and (2) mark the QBO short-paid invoices factored.

create or replace function public.factoring_overview()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare res jsonb; inv jsonb;
begin
  if public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select jsonb_build_object(
    'factored_count',  count(*) filter (where i.status='sent'),
    'total_factored',  coalesce(sum(i.total),0),
    'advanced',        coalesce(sum(i.total - case when i.status='sent' then public.invoice_balance(i) else 0 end),0),
    'reserve_pending', coalesce(sum(case when i.status='sent' then public.invoice_balance(i) else 0 end),0),
    'fees',            coalesce(sum(i.factoring_fee),0)
  ) into res
  from public.invoices i where i.factored_at is not null;

  select coalesce(jsonb_agg(row order by (row->>'reserve_pending')::numeric desc), '[]'::jsonb) into inv from (
    select jsonb_build_object(
      'id', i.id, 'invoice_number', i.invoice_number,
      'customer', c.company_name,
      'total', i.total,
      'advanced', i.total - case when i.status='sent' then public.invoice_balance(i) else 0 end,
      'reserve_pending', case when i.status='sent' then public.invoice_balance(i) else 0 end,
      'fee', i.factoring_fee,
      'factor', i.factor_name,
      'factored_at', i.factored_at,
      'reserve_released', (i.status='paid')
    ) as row
    from public.invoices i left join public.customers c on c.id=i.customer_id
    where i.factored_at is not null
  ) x;

  return jsonb_build_object('summary', res, 'invoices', inv);
end; $$;
revoke all on function public.factoring_overview() from public, anon;
grant execute on function public.factoring_overview() to authenticated, service_role;

-- Backfill: QBO short-paid open invoices (0 < qbo_balance < total) are the factored
-- ones (owner-stated). factored_at ~ when we learned of the advance (qbo sync/issue).
update public.invoices i
   set factored_at = coalesce(i.factored_at, i.qbo_synced_at, i.invoice_date),
       factor_name = coalesce(i.factor_name, 'Denim')
 where i.status = 'sent'
   and i.source = 'qbo'
   and coalesce(i.qbo_balance, i.total) > 0
   and coalesce(i.qbo_balance, i.total) < i.total;

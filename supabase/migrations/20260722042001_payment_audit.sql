-- R9 #37: payment-application audit. Three ways a payment lands wrong, each
-- as a named list: marked paid here but QBO still shows a balance (payment on
-- the wrong invoice or never entered in the books), collected in QBO but
-- still open here (mark it!), and payments recorded past the invoice total
-- (misapplied or double-entered).
create or replace function public.payment_application_audit()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when auth.role() = 'service_role' or public.my_role() in ('admin','accountant')
  then jsonb_build_object(
    'paid_but_open_in_qbo', coalesce((select jsonb_agg(jsonb_build_object(
        'invoice', i.invoice_number, 'customer', c.company_name,
        'total', i.total, 'qbo_balance', i.qbo_balance) order by i.qbo_balance desc)
      from invoices i left join customers c on c.id = i.customer_id
      where i.status = 'paid' and i.source = 'qbo' and i.qbo_balance > 0), '[]'::jsonb),
    'settled_in_qbo_but_open', coalesce((select jsonb_agg(jsonb_build_object(
        'invoice', i.invoice_number, 'customer', c.company_name, 'total', i.total,
        'days_open', (current_date - i.invoice_date)) order by i.invoice_date)
      from invoices i left join customers c on c.id = i.customer_id
      where i.status = 'sent' and i.source = 'qbo' and i.qbo_balance = 0
        and i.factored_at is null), '[]'::jsonb),
    'overpaid', coalesce((select jsonb_agg(jsonb_build_object(
        'invoice', x.invoice_number, 'customer', x.company_name,
        'total', x.total, 'payments', x.paid) order by x.paid - x.total desc)
      from (select i.invoice_number, c.company_name, i.total, sum(p.amount) paid
              from invoice_payments p
              join invoices i on i.id = p.invoice_id
              left join customers c on c.id = i.customer_id
             where i.status <> 'void'
             group by i.id, i.invoice_number, c.company_name, i.total
            having sum(p.amount) > i.total + 0.01) x), '[]'::jsonb),
    'as_of', now())
  end;
$$;
revoke all on function public.payment_application_audit() from public, anon;
grant execute on function public.payment_application_audit() to authenticated, service_role;

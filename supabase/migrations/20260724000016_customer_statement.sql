-- R9 #33: per-customer account statement. Brokers and factors ask for a
-- statement of account — every invoice in a window with what was billed, what
-- was paid, and the balance carried, plus an opening balance so the running
-- total ties out. Built from the invoices ledger (native + QBO-mirrored),
-- balances via the one invoice_balance() rule. Printable on the frontend.
create or replace function public.customer_statement(p_customer_id bigint, p_start date, p_end date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
  v_opening numeric;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;

  -- opening balance: unpaid balance on everything invoiced before the window
  select coalesce(sum(public.invoice_balance(i)), 0) into v_opening
    from invoices i
   where i.customer_id = p_customer_id and i.status <> 'draft'
     and i.invoice_date::date < p_start;

  select jsonb_build_object(
    'customer', (select company_name from customers where id = p_customer_id),
    'period', jsonb_build_object('start', p_start, 'end', p_end),
    'opening_balance', round(v_opening, 2),
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
        'invoice', coalesce(nullif(i.invoice_number,''), '#'||i.id),
        'invoice_date', i.invoice_date::date,
        'due_date', i.due_date::date,
        'total', round(i.total, 2),
        'status', i.status,
        'balance', round(public.invoice_balance(i), 2))
        order by i.invoice_date, i.id)
      from invoices i
     where i.customer_id = p_customer_id and i.status <> 'draft'
       and i.invoice_date::date between p_start and p_end), '[]'::jsonb),
    'billed_in_period', (select coalesce(round(sum(i.total), 2), 0) from invoices i
       where i.customer_id = p_customer_id and i.status <> 'draft'
         and i.invoice_date::date between p_start and p_end),
    'closing_balance', round(v_opening + coalesce((select sum(public.invoice_balance(i)) from invoices i
       where i.customer_id = p_customer_id and i.status <> 'draft'
         and i.invoice_date::date between p_start and p_end), 0), 2),
    'note', 'balances via invoice_balance() (QBO rows trust the books); drafts excluded — a statement lists what was actually billed',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.customer_statement(bigint, date, date) from public, anon, authenticated;
grant execute on function public.customer_statement(bigint, date, date) to authenticated, service_role;

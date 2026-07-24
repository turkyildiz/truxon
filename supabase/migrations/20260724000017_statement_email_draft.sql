-- R9 #34: customer statement email DRAFT — propose-only. Pairs with #33: turns
-- a statement of account into a ready-to-send email (recipient, subject, body)
-- for the office to review and send by hand. Nothing sends from here — this is
-- the draft, not the send button. Uses the customer's email on file when it
-- exists, else flags that a recipient is missing.
create or replace function public.customer_statement_email_draft(p_customer_id bigint, p_start date, p_end date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  s jsonb;
  c customers;
  body text;
  lines text := '';
  ln jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  select * into c from customers where id = p_customer_id;
  if not found then raise exception 'Customer not found'; end if;
  s := public.customer_statement(p_customer_id, p_start, p_end);

  for ln in select * from jsonb_array_elements(s->'lines') loop
    lines := lines || '  ' || (ln->>'invoice') || '  ' || (ln->>'invoice_date')
             || '  ' || to_char((ln->>'total')::numeric, 'FM$999,999,990.00')
             || '  ' || (ln->>'status')
             || '  bal ' || to_char((ln->>'balance')::numeric, 'FM$999,999,990.00') || E'\n';
  end loop;

  body := 'Hello,' || E'\n\n'
    || 'Please find your statement of account with Aida Logistics for '
    || to_char(p_start, 'Mon DD') || ' to ' || to_char(p_end, 'Mon DD, YYYY') || '.' || E'\n\n'
    || 'Opening balance: ' || to_char((s->>'opening_balance')::numeric, 'FM$999,999,990.00') || E'\n'
    || 'Billed this period: ' || to_char((s->>'billed_in_period')::numeric, 'FM$999,999,990.00') || E'\n'
    || 'Closing balance: ' || to_char((s->>'closing_balance')::numeric, 'FM$999,999,990.00') || E'\n\n'
    || case when lines <> '' then 'Invoices:' || E'\n' || lines || E'\n' else '' end
    || 'Please remit any open balance at your earliest convenience, and reply with any questions.' || E'\n\n'
    || 'Thank you,' || E'\n' || 'Aida Logistics — Accounts Receivable';

  return jsonb_build_object(
    'to', nullif(c.email, ''),
    'has_recipient', c.email <> '',
    'subject', 'Statement of account — ' || c.company_name || ' — ' || to_char(p_end, 'Mon YYYY'),
    'body', body,
    'closing_balance', (s->>'closing_balance')::numeric,
    'note', 'propose-only: review and send this from your mail client. Nothing is emailed automatically.' ,
    'as_of', now());
end;
$$;
revoke all on function public.customer_statement_email_draft(bigint, date, date) from public, anon, authenticated;
grant execute on function public.customer_statement_email_draft(bigint, date, date) to authenticated, service_role;

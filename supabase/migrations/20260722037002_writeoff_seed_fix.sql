-- Hotfix: the Denim fee sync now writes the TRUE total fee (factoring +
-- servicing) onto factoring_fee, so the seed's qbo_balance = factoring_fee
-- equality stopped matching (114 of 116 slivers). Seed on the sliver CLASS
-- (small factored residual balance) and propose the BOOK balance — what's
-- actually left to write off — not Denim's fee figure.
create or replace function public.qbo_writeoff_seed()
returns int
language plpgsql security definer set search_path = public
as $$
declare n int;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','accountant') then
    raise exception 'Not enough permissions';
  end if;
  insert into qbo_writeoff_proposals (invoice_id, amount)
  select i.id, i.qbo_balance
    from invoices i
   where i.factored_at is not null
     and i.status = 'sent'
     and i.source = 'qbo'
     and i.qbo_balance > 0
     and i.qbo_balance <= least(0.15 * i.total, 500)
     and not exists (select 1 from qbo_writeoff_proposals p where p.invoice_id = i.id)
  on conflict (invoice_id) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.qbo_writeoff_seed() from public, anon;
grant execute on function public.qbo_writeoff_seed() to authenticated, service_role;

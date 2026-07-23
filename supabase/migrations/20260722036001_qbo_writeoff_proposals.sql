-- R9 #29: factoring-fee write-off PROPOSALS. The 116 fee slivers ($17.4k)
-- sitting on the books as fake receivables get one proposal card each; the
-- owner approves or dismisses. Truxon NEVER writes these to QBO — an approved
-- proposal joins the accountant packet (customer, invoice, amount, memo) to
-- apply in QBO by hand; the 30-min mirror then clears the sliver here.
create table if not exists public.qbo_writeoff_proposals (
  id bigserial primary key,
  invoice_id bigint not null unique references public.invoices(id) on delete cascade,
  amount numeric not null,
  status text not null default 'proposed' check (status in ('proposed','approved','dismissed')),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.qbo_writeoff_proposals enable row level security;
revoke all on public.qbo_writeoff_proposals from anon, authenticated;
grant select on public.qbo_writeoff_proposals to authenticated;
drop policy if exists qwp_select on public.qbo_writeoff_proposals;
create policy qwp_select on public.qbo_writeoff_proposals
  for select to authenticated using (public.my_role() in ('admin','accountant'));
insert into app_private.security_baseline (kind, item)
values ('grant', 'authenticated qbo_writeoff_proposals SELECT')
on conflict do nothing;

-- Idempotent: one proposal per live fee sliver that doesn't have one yet.
-- A sliver whose balance already cleared in QBO never gets (re)proposed.
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
  select i.id, i.factoring_fee
    from invoices i
   where i.factored_at is not null
     and coalesce(i.factoring_fee, 0) > 0
     and i.status = 'sent'
     and i.qbo_balance = i.factoring_fee
     and not exists (select 1 from qbo_writeoff_proposals p where p.invoice_id = i.id)
  on conflict (invoice_id) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.qbo_writeoff_seed() from public, anon;
grant execute on function public.qbo_writeoff_seed() to authenticated, service_role;

-- Approve/dismiss. Approval changes STATUS ONLY — no book write, ever.
create or replace function public.qbo_writeoff_decide(p_id bigint, p_approve boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if public.my_role() not in ('admin','accountant') then
    raise exception 'Not enough permissions';
  end if;
  update qbo_writeoff_proposals
     set status = case when p_approve then 'approved' else 'dismissed' end,
         decided_by = auth.uid(), decided_at = now()
   where id = p_id and status = 'proposed';
  if not found then
    raise exception 'Proposal not found or already decided' using errcode = 'P0002';
  end if;
end;
$$;
revoke all on function public.qbo_writeoff_decide(bigint, boolean) from public, anon;
grant execute on function public.qbo_writeoff_decide(bigint, boolean) to authenticated;

-- The card + accountant packet in one call.
create or replace function public.qbo_writeoff_list()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when auth.role() = 'service_role' or public.my_role() in ('admin','accountant')
  then jsonb_build_object(
    'proposed_total', coalesce((select sum(amount) from qbo_writeoff_proposals where status = 'proposed'), 0),
    'approved_total', coalesce((select sum(amount) from qbo_writeoff_proposals where status = 'approved'), 0),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'status', p.status, 'amount', p.amount,
        'invoice_number', i.invoice_number, 'invoice_date', i.invoice_date,
        'customer', c.company_name, 'factor', i.factor_name)
        order by p.status, i.invoice_date)
      from qbo_writeoff_proposals p
      join invoices i on i.id = p.invoice_id
      left join customers c on c.id = i.customer_id
      where p.status <> 'dismissed'), '[]'::jsonb))
  end;
$$;
revoke all on function public.qbo_writeoff_list() from public, anon;
grant execute on function public.qbo_writeoff_list() to authenticated, service_role;

-- Seed tonight's known slivers so the card isn't empty on first open.
select public.qbo_writeoff_seed();

-- Factoring MVP (interim, before the Denim API sync). Aida factors invoices:
-- the factor advances ~90% now and releases the ~10% reserve (minus a fee) later.
-- Truxon was showing the unreleased reserve as broker "past due" — a false signal.
-- This marks an invoice `factored`, so its reserve is a FACTORING RESERVE (owed by
-- the factor), NOT broker A/R: it leaves past-due / aging / DSO, and lands in a
-- Factoring view instead. The Denim API sync will later post advances/reserves/fees
-- automatically; for now advance = payments recorded, reserve = remaining balance,
-- fee = TBD from the agreement.

alter table public.invoices
  add column if not exists factored_at   timestamptz,
  add column if not exists factor_name   text,
  add column if not exists factoring_fee numeric;   -- filled once Denim/agreement is in

comment on column public.invoices.factored_at is 'When this invoice was sold to a factor; non-null = factored (out of broker collections).';

create index if not exists invoices_factored_idx on public.invoices (factored_at) where factored_at is not null;

-- ── mark / unmark factored (admin) ──────────────────────────────────────────
create or replace function public.mark_invoice_factored(
  p_id bigint, p_factor text default 'Denim', p_fee numeric default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'admin' then raise exception 'Not enough permissions'; end if;
  update public.invoices
     set factored_at = coalesce(factored_at, now()),
         factor_name = coalesce(p_factor, 'Denim'),
         factoring_fee = coalesce(p_fee, factoring_fee)
   where id = p_id and status <> 'void';
  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
    values ('invoice', p_id, auth.uid(), 'marked_factored', 'Factored via '||coalesce(p_factor,'Denim'));
end; $$;
revoke all on function public.mark_invoice_factored(bigint, text, numeric) from public, anon;

create or replace function public.unmark_invoice_factored(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'admin' then raise exception 'Not enough permissions'; end if;
  update public.invoices set factored_at = null where id = p_id;
  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
    values ('invoice', p_id, auth.uid(), 'unmarked_factored', 'Un-factored (back to broker A/R)');
end; $$;
revoke all on function public.unmark_invoice_factored(bigint) from public, anon;

-- ── Factoring overview (the new section) ────────────────────────────────────
create or replace function public.factoring_overview()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare res jsonb; inv jsonb;
begin
  if public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select jsonb_build_object(
    'factored_count',  count(*),
    'total_factored',  coalesce(sum(i.total),0),
    'advanced',        coalesce(sum(coalesce((select sum(p.amount) from invoice_payments p where p.invoice_id=i.id),0)),0),
    'reserve_pending', coalesce(sum(case when i.status='sent' then public.invoice_balance(i) else 0 end),0),
    'reserve_released',coalesce(sum(case when i.status='paid' then public.invoice_balance_raw(i) else 0 end),0),
    'fees',            coalesce(sum(i.factoring_fee),0)
  ) into res
  from public.invoices i where i.factored_at is not null;

  select coalesce(jsonb_agg(row order by (row->>'factored_at') desc), '[]'::jsonb) into inv from (
    select jsonb_build_object(
      'id', i.id, 'invoice_number', i.invoice_number,
      'customer', c.company_name,
      'total', i.total,
      'advanced', coalesce((select sum(p.amount) from invoice_payments p where p.invoice_id=i.id),0),
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

-- raw balance helper (invoice_balance short-circuits paid rows to 0)
create or replace function public.invoice_balance_raw(i public.invoices)
returns numeric language sql security definer set search_path = public stable as $$
  select case when i.source='qbo' then coalesce(i.qbo_balance,i.total)
              else i.total - coalesce((select sum(p.amount) from invoice_payments p where p.invoice_id=i.id),0) end;
$$;

-- ── EXCLUDE factored invoices from broker A/R, past-due, aging, DSO ──────────
create or replace function public.acct_summary()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare v_ar numeric; v_billed90 numeric; v_reserve numeric;
begin
  if public.my_role() <> 'admin' then raise exception 'Not enough permissions'; end if;
  select coalesce(sum(public.invoice_balance(i)),0) into v_ar
    from invoices i where i.status='sent' and i.factored_at is null;
  select coalesce(sum(public.invoice_balance(i)),0) into v_reserve
    from invoices i where i.status='sent' and i.factored_at is not null;
  select coalesce(sum(total),0) into v_billed90
    from invoices where status<>'void' and invoice_date >= now()-interval '90 days';
  return jsonb_build_object(
    'ar_total', v_ar,
    'ar_past_due', (select coalesce(sum(public.invoice_balance(i)),0) from invoices i
                      where i.status='sent' and i.factored_at is null and i.due_date < now()),
    'past_due_count', (select count(*) from invoices where status='sent' and factored_at is null and due_date < now()),
    'open_count', (select count(*) from invoices where status='sent' and factored_at is null),
    'factoring_reserve', v_reserve,
    'factored_count', (select count(*) from invoices where factored_at is not null and status='sent'),
    'dso', case when v_billed90>0 then round(v_ar/v_billed90*90,1) end,
    'avg_days_to_pay', (select round(avg(extract(epoch from paid_at-invoice_date)/86400)::numeric,1)
                          from invoices where status='paid' and paid_at is not null
                            and invoice_date >= now()-interval '180 days'),
    'unbilled_total', (select coalesce(sum(rate),0) from loads where status='completed' and invoice_id is null),
    'unbilled_count', (select count(*) from loads where status='completed' and invoice_id is null),
    'mtd_billed', (select coalesce(sum(total),0) from invoices where status<>'void' and invoice_date >= date_trunc('month',now())),
    'mtd_collected', (select coalesce(sum(total),0) from invoices where paid_at >= date_trunc('month',now()))
  );
end; $$;
revoke all on function public.acct_summary() from public, anon;

create or replace function public.acct_aging()
returns table (customer_id bigint, customer_name text, current_due numeric,
  d1_30 numeric, d31_60 numeric, d61_90 numeric, d90_plus numeric, total numeric, invoice_count bigint)
language plpgsql security definer set search_path = public stable as $$
begin
  if public.my_role() <> 'admin' then raise exception 'Not enough permissions'; end if;
  return query
  select c.id, c.company_name,
    sum(case when i.due_date >= now() then public.invoice_balance(i) else 0 end),
    sum(case when i.due_date < now() and i.due_date >= now()-interval '30 days' then public.invoice_balance(i) else 0 end),
    sum(case when i.due_date < now()-interval '30 days' and i.due_date >= now()-interval '60 days' then public.invoice_balance(i) else 0 end),
    sum(case when i.due_date < now()-interval '60 days' and i.due_date >= now()-interval '90 days' then public.invoice_balance(i) else 0 end),
    sum(case when i.due_date < now()-interval '90 days' then public.invoice_balance(i) else 0 end),
    sum(public.invoice_balance(i)), count(*)
  from invoices i join customers c on c.id=i.customer_id
  where i.status='sent' and i.factored_at is null      -- factored reserves are not broker A/R
  group by c.id, c.company_name order by 7 desc;
end; $$;
revoke all on function public.acct_aging() from public, anon;

-- ── Backfill: the short-paid open invoices ARE the factored ones (owner-stated).
-- Mark them factored so the section stops showing false past-due. factored_at =
-- the advance (first payment) date. Reversible via unmark_invoice_factored().
update public.invoices i
   set factored_at = coalesce(i.factored_at,
         (select min(p.received_at) from public.invoice_payments p where p.invoice_id=i.id)),
       factor_name = coalesce(i.factor_name, 'Denim')
 where i.status = 'sent'
   and i.source = 'truxon'
   and public.invoice_balance(i) > 0
   and exists (select 1 from public.invoice_payments p where p.invoice_id=i.id);

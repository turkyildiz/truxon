-- Accounting module — Truxon as the complete money system (QuickBooks becomes
-- optional: the QBO mirror keeps working, but nothing here depends on it).
--
--   invoice_payments             checks/ACH/wire/factoring, partials supported
--   record_invoice_payment()     post a payment; auto-flips paid at zero balance
--   invoice_balance()            one balance rule: QBO rows trust the books,
--                                Truxon rows compute total − payments
--   invoices.paid_at / sent_at   when money arrived / when it was emailed
--   acct_summary()               KPI strip: DSO, A/R, past due, unbilled, MTD
--   acct_aging()                 per-customer receivable buckets
--   acct_unbilled_loads()        completed loads never invoiced (revenue leak)
--   acct_revenue_monthly()       billed vs collected by month
--   acct_revenue_by_customer()   broker revenue + concentration + pay behavior
--   acct_margin_monthly()        revenue vs direct costs (fuel+tolls+MX)
-- All admin-gated: this is the owner's money view.

-- ── timestamps ──────────────────────────────────────────────────────────────
alter table public.invoices
  add column paid_at timestamptz,
  add column sent_at timestamptz,
  add column sent_to text;

create or replace function public.invoices_set_paid_at()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'paid' and (old.status is distinct from 'paid') and new.paid_at is null then
    new.paid_at := now();
  end if;
  if new.status <> 'paid' and old.status = 'paid' then
    new.paid_at := null;  -- payment reversed
  end if;
  return new;
end;
$$;
create trigger trg_invoices_paid_at
  before update on public.invoices
  for each row execute function public.invoices_set_paid_at();

-- Backfill: QBO mirrors flipped paid carry the sync stamp (the moment we
-- learned it was paid). Truxon-native paid rows use their activity trail if
-- one exists; otherwise they stay null and don't feed days-to-pay averages.
update public.invoices set paid_at = qbo_synced_at
  where status = 'paid' and source = 'qbo' and paid_at is null and qbo_synced_at is not null;
update public.invoices i set paid_at = a.created_at
  from (
    select entity_id, min(created_at) as created_at
    from public.activity_log
    where entity_type = 'invoice' and detail ilike '%paid%'
    group by entity_id
  ) a
  where i.id = a.entity_id and i.status = 'paid' and i.paid_at is null;

-- ── payments ledger ─────────────────────────────────────────────────────────
create table public.invoice_payments (
  id bigint generated always as identity primary key,
  invoice_id bigint not null references public.invoices(id) on delete cascade,
  amount numeric not null check (amount > 0),
  method text not null default 'check' check (method in ('check', 'ach', 'wire', 'card', 'factoring', 'other')),
  reference text,
  notes text,
  received_at timestamptz not null default now(),
  recorded_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index on public.invoice_payments (invoice_id);
alter table public.invoice_payments enable row level security;
create policy invoice_payments_staff_read on public.invoice_payments
  for select using (public.my_role() in ('admin', 'dispatcher'));
-- writes only through the RPC below

-- One balance rule everywhere: QBO mirrors trust the books' balance;
-- Truxon-native invoices compute total minus recorded payments.
create or replace function public.invoice_balance(i public.invoices)
returns numeric
language sql
security definer
set search_path = public
stable
as $$
  select case
    when i.status = 'paid' or i.status = 'void' then 0
    when i.source = 'qbo' then coalesce(i.qbo_balance, i.total)
    else i.total - coalesce((select sum(p.amount) from invoice_payments p where p.invoice_id = i.id), 0)
  end;
$$;

create or replace function public.record_invoice_payment(
  p_invoice_id bigint,
  p_amount numeric,
  p_method text default 'check',
  p_reference text default null,
  p_received_at timestamptz default now(),
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv invoices;
  v_balance numeric;
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  select * into inv from invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice_not_found'; end if;
  if inv.status = 'void' then raise exception 'Cannot record a payment on a void invoice'; end if;
  if inv.status = 'draft' then raise exception 'Send the invoice before recording payments'; end if;
  if p_amount <= 0 then raise exception 'Payment must be positive'; end if;

  insert into invoice_payments (invoice_id, amount, method, reference, received_at, recorded_by, notes)
    values (p_invoice_id, p_amount, p_method, p_reference, p_received_at, auth.uid(), p_notes);

  select public.invoice_balance(i) into v_balance from invoices i where i.id = p_invoice_id;
  if v_balance <= 0 and inv.status <> 'paid' then
    update invoices set status = 'paid', paid_at = p_received_at where id = p_invoice_id;
  end if;

  insert into activity_log (entity_type, entity_id, user_id, action, detail)
    values ('invoice', p_invoice_id, auth.uid(), 'payment_recorded',
            inv.invoice_number || ': $' || p_amount || ' by ' || p_method ||
            coalesce(' (' || p_reference || ')', '') ||
            case when v_balance <= 0 then ' — PAID IN FULL' else ' — $' || v_balance || ' remaining' end);

  return jsonb_build_object('balance', greatest(v_balance, 0), 'paid', v_balance <= 0);
end;
$$;
revoke all on function public.record_invoice_payment(bigint, numeric, text, text, timestamptz, text) from public, anon;

-- Undo a mis-keyed payment (admin): removes it and reopens the invoice if needed.
create or replace function public.delete_invoice_payment(p_payment_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invoice bigint;
  v_balance numeric;
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  delete from invoice_payments where id = p_payment_id returning invoice_id into v_invoice;
  if v_invoice is null then raise exception 'payment_not_found'; end if;
  -- raw balance (invoice_balance() short-circuits paid rows to 0, which would
  -- mask the reopen condition here)
  select i.total - coalesce((select sum(p.amount) from invoice_payments p where p.invoice_id = i.id), 0)
    into v_balance from invoices i where i.id = v_invoice;
  update invoices set status = 'sent', paid_at = null
    where id = v_invoice and status = 'paid' and source = 'truxon' and v_balance > 0;
end;
$$;
revoke all on function public.delete_invoice_payment(bigint) from public, anon;

create or replace function public.list_invoice_payments(p_invoice_id bigint)
returns setof public.invoice_payments
language sql
security definer
set search_path = public
stable
as $$
  select p.* from invoice_payments p
  where p.invoice_id = p_invoice_id and public.my_role() in ('admin', 'dispatcher')
  order by p.received_at desc;
$$;
revoke all on function public.list_invoice_payments(bigint) from public, anon;

-- ── KPI summary ─────────────────────────────────────────────────────────────
create or replace function public.acct_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_ar numeric;
  v_billed90 numeric;
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(public.invoice_balance(i)), 0) into v_ar
    from invoices i where i.status = 'sent';
  select coalesce(sum(total), 0) into v_billed90
    from invoices where status <> 'void' and invoice_date >= now() - interval '90 days';

  return jsonb_build_object(
    'ar_total', v_ar,
    'ar_past_due', (select coalesce(sum(public.invoice_balance(i)), 0) from invoices i
                      where i.status = 'sent' and i.due_date < now()),
    'past_due_count', (select count(*) from invoices where status = 'sent' and due_date < now()),
    'open_count', (select count(*) from invoices where status = 'sent'),
    -- DSO (90-day standard): receivables ÷ billed × window
    'dso', case when v_billed90 > 0 then round(v_ar / v_billed90 * 90, 1) end,
    'avg_days_to_pay', (select round(avg(extract(epoch from paid_at - invoice_date) / 86400)::numeric, 1)
                          from invoices
                          where status = 'paid' and paid_at is not null
                            and invoice_date >= now() - interval '180 days'),
    'unbilled_total', (select coalesce(sum(rate), 0) from loads
                         where status = 'completed' and invoice_id is null),
    'unbilled_count', (select count(*) from loads where status = 'completed' and invoice_id is null),
    'mtd_billed', (select coalesce(sum(total), 0) from invoices
                     where status <> 'void' and invoice_date >= date_trunc('month', now())),
    'mtd_collected', (select coalesce(sum(total), 0) from invoices
                        where paid_at >= date_trunc('month', now()))
  );
end;
$$;
revoke all on function public.acct_summary() from public, anon;

-- ── Aging by customer ───────────────────────────────────────────────────────
create or replace function public.acct_aging()
returns table (
  customer_id bigint,
  customer_name text,
  current_due numeric,
  d1_30 numeric,
  d31_60 numeric,
  d61_90 numeric,
  d90_plus numeric,
  total numeric,
  invoice_count bigint
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return query
  select
    c.id, c.company_name,
    sum(case when i.due_date >= now() then public.invoice_balance(i) else 0 end),
    sum(case when i.due_date < now() and i.due_date >= now() - interval '30 days' then public.invoice_balance(i) else 0 end),
    sum(case when i.due_date < now() - interval '30 days' and i.due_date >= now() - interval '60 days' then public.invoice_balance(i) else 0 end),
    sum(case when i.due_date < now() - interval '60 days' and i.due_date >= now() - interval '90 days' then public.invoice_balance(i) else 0 end),
    sum(case when i.due_date < now() - interval '90 days' then public.invoice_balance(i) else 0 end),
    sum(public.invoice_balance(i)),
    count(*)
  from invoices i join customers c on c.id = i.customer_id
  where i.status = 'sent'
  group by c.id, c.company_name
  order by 7 desc;
end;
$$;
revoke all on function public.acct_aging() from public, anon;

-- ── Unbilled loads (the leak) ───────────────────────────────────────────────
create or replace function public.acct_unbilled_loads()
returns table (
  load_id bigint,
  load_number text,
  customer_id bigint,
  customer_name text,
  delivered_at timestamptz,
  days_unbilled numeric,
  rate numeric
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return query
  select
    l.id, l.load_number, c.id, c.company_name,
    l.delivery_time,
    round(extract(epoch from now() - coalesce(l.delivery_time, l.updated_at)) / 86400),
    l.rate
  from loads l join customers c on c.id = l.customer_id
  where l.status = 'completed' and l.invoice_id is null
  order by 6 desc;
end;
$$;
revoke all on function public.acct_unbilled_loads() from public, anon;

-- ── Billed vs collected by month ────────────────────────────────────────────
create or replace function public.acct_revenue_monthly(p_months int default 12)
returns table (month text, billed numeric, collected numeric)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return query
  with months as (
    select date_trunc('month', now()) - (interval '1 month' * g) as m
    from generate_series(least(greatest(p_months, 1), 36) - 1, 0, -1) g
  )
  select
    to_char(m.m, 'YYYY-MM'),
    coalesce((select sum(total) from invoices i where i.status <> 'void' and date_trunc('month', i.invoice_date) = m.m), 0),
    coalesce((select sum(total) from invoices i where i.paid_at is not null and date_trunc('month', i.paid_at) = m.m), 0)
  from months m
  order by 1;
end;
$$;
revoke all on function public.acct_revenue_monthly(int) from public, anon;

-- ── Revenue by customer + concentration + pay behavior ──────────────────────
create or replace function public.acct_revenue_by_customer(p_days int default 365)
returns table (
  customer_id bigint,
  customer_name text,
  billed numeric,
  share_pct numeric,
  open_balance numeric,
  past_due numeric,
  avg_days_to_pay numeric,
  invoice_count bigint
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_total numeric;
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(sum(total), 0) into v_total
    from invoices where status <> 'void' and invoice_date >= now() - (p_days || ' days')::interval;
  return query
  select
    c.id, c.company_name,
    coalesce(sum(i.total) filter (where i.status <> 'void'), 0),
    case when v_total > 0 then round(coalesce(sum(i.total) filter (where i.status <> 'void'), 0) / v_total * 100, 1) end,
    coalesce(sum(public.invoice_balance(i)) filter (where i.status = 'sent'), 0),
    coalesce(sum(public.invoice_balance(i)) filter (where i.status = 'sent' and i.due_date < now()), 0),
    round(avg(extract(epoch from i.paid_at - i.invoice_date) / 86400) filter (where i.paid_at is not null)::numeric, 1),
    count(*)
  from invoices i join customers c on c.id = i.customer_id
  where i.invoice_date >= now() - (p_days || ' days')::interval
  group by c.id, c.company_name
  order by 3 desc;
end;
$$;
revoke all on function public.acct_revenue_by_customer(int) from public, anon;

-- ── Direct-cost margin by month (fuel + tolls + maintenance) ────────────────
create or replace function public.acct_margin_monthly(p_months int default 12)
returns table (
  month text,
  revenue numeric,
  fuel numeric,
  tolls numeric,
  maintenance numeric,
  margin numeric,
  operating_ratio numeric
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return query
  with months as (
    select date_trunc('month', now()) - (interval '1 month' * g) as m
    from generate_series(least(greatest(p_months, 1), 36) - 1, 0, -1) g
  ),
  rev as (
    select date_trunc('month', invoice_date) m, sum(total) v from invoices where status <> 'void' group by 1
  ),
  fu as (
    select date_trunc('month', posted_date) m, sum(amount) v from fuel_transactions group by 1
  ),
  tl as (
    select date_trunc('month', coalesce(exit_date_time, post_date_time)) m, sum(toll_charge) v from toll_transactions group by 1
  ),
  mx as (
    select date_trunc('month', date_completed) m, sum(cost) v from maintenance_records where date_completed is not null group by 1
  )
  select
    to_char(months.m, 'YYYY-MM'),
    coalesce(rev.v, 0),
    coalesce(fu.v, 0),
    coalesce(tl.v, 0),
    coalesce(mx.v, 0),
    coalesce(rev.v, 0) - coalesce(fu.v, 0) - coalesce(tl.v, 0) - coalesce(mx.v, 0),
    case when coalesce(rev.v, 0) > 0
      then round((coalesce(fu.v, 0) + coalesce(tl.v, 0) + coalesce(mx.v, 0)) / rev.v * 100, 1) end
  from months
  left join rev on rev.m = months.m
  left join fu on fu.m = months.m
  left join tl on tl.m = months.m
  left join mx on mx.m = months.m
  order by 1;
end;
$$;
revoke all on function public.acct_margin_monthly(int) from public, anon;

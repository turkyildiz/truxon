-- R9 #36: credit-memo tracking from the QBO mirror. Credit memos are the
-- billing-error ledger — every one is revenue walked back. Mirror them,
-- compute the credit-memo rate / invoice accuracy, and flip playbook #72/#73.
create table if not exists public.qbo_credit_memos (
  qbo_id text primary key,
  doc_number text,
  customer_qbo_id text,
  txn_date date,
  total numeric,
  balance numeric,
  memo text,
  updated_at timestamptz not null default now()
);
alter table public.qbo_credit_memos enable row level security;
revoke all on public.qbo_credit_memos from anon, authenticated;
grant select on public.qbo_credit_memos to authenticated;
drop policy if exists qcm_select on public.qbo_credit_memos;
create policy qcm_select on public.qbo_credit_memos
  for select to authenticated using (public.my_role() in ('admin','accountant'));
insert into app_private.security_baseline (kind, item)
values ('grant', 'authenticated qbo_credit_memos SELECT')
on conflict do nothing;

alter table public.qbo_sync_state add column if not exists cm_backfilled boolean not null default false;

create or replace function public.qbo_upsert_credit_memos(p_rows jsonb)
returns int
language plpgsql security definer set search_path = public
as $$
declare n int;
begin
  -- service only (post-rotation convention: service calls carry no user)
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  insert into qbo_credit_memos (qbo_id, doc_number, customer_qbo_id, txn_date, total, balance, memo, updated_at)
  select r->>'qbo_id', r->>'doc_number', r->>'customer_qbo_id',
         (r->>'txn_date')::date, (r->>'total')::numeric, (r->>'balance')::numeric,
         r->>'memo', now()
    from jsonb_array_elements(p_rows) r
   where coalesce(r->>'qbo_id','') <> ''
  on conflict (qbo_id) do update set
    doc_number = excluded.doc_number, customer_qbo_id = excluded.customer_qbo_id,
    txn_date = excluded.txn_date, total = excluded.total, balance = excluded.balance,
    memo = excluded.memo, updated_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.qbo_upsert_credit_memos(jsonb) from public, anon, authenticated;
grant execute on function public.qbo_upsert_credit_memos(jsonb) to service_role;

create or replace function public.credit_memo_summary(p_months int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_since date := date_trunc('month', current_date) - make_interval(months => p_months);
  v_cm numeric;
  v_n int;
  v_inv numeric;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','accountant') then
    raise exception 'Not enough permissions';
  end if;
  select count(*), coalesce(sum(total), 0) into v_n, v_cm
    from qbo_credit_memos where txn_date >= v_since;
  select coalesce(sum(total), 0) into v_inv
    from invoices where status <> 'void' and invoice_date >= v_since;
  return jsonb_build_object(
    'months', p_months,
    'credit_memos', v_n,
    'credit_memo_total', round(v_cm, 2),
    'invoiced_total', round(v_inv, 2),
    'credit_memo_rate_pct', round(v_cm / nullif(v_inv, 0) * 100, 2),
    'invoice_accuracy_pct', round(100 - coalesce(v_cm / nullif(v_inv, 0) * 100, 0), 2),
    'recent', coalesce((select jsonb_agg(jsonb_build_object(
        'doc', m.doc_number, 'date', m.txn_date, 'total', m.total,
        'customer', c.company_name, 'memo', m.memo) order by m.txn_date desc)
      from (select * from qbo_credit_memos order by txn_date desc limit 10) m
      left join customers c on c.qbo_id = m.customer_qbo_id), '[]'::jsonb),
    'as_of', now());
end;
$$;
revoke all on function public.credit_memo_summary(int) from public, anon;
grant execute on function public.credit_memo_summary(int) to authenticated, service_role;

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'credit_memo_summary(months) — QBO credit-memo mirror (30-min sync)'
where number in (72, 73) and status <> 'live';

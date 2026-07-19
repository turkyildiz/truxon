-- QuickBooks Online sync — transition mode: QBO stays the books of record and
-- Truxon mirrors its invoices (AR truth flows in), until the owner flips to
-- Truxon-first push. Single-tenant: one QBO company (realm).
--
--   qbo_connection   OAuth tokens + realm (RLS with no policies: service only —
--                    tokens must never reach a browser client)
--   qbo_sync_state   watermark + last-result bookkeeping for the pull cron
--   invoices         source ('truxon'|'qbo') + qbo_* mirror columns
--   customers        qbo_id mapping (matched by exact name, else auto-created)
--   qbo_upsert_invoices(jsonb)  service-gated bulk upsert used by the pull
--   qbo_mark_voided(jsonb)      service-gated: CDC-deleted invoices → void
--   qbo_status()                admin-gated status card for the frontend

-- ── connection + state ──────────────────────────────────────────────────────
create table public.qbo_connection (
  id smallint primary key default 1 check (id = 1),
  realm_id text not null,
  access_token text not null,
  refresh_token text not null,
  access_expires_at timestamptz not null,
  refresh_expires_at timestamptz not null,
  oauth_state text,
  connected_at timestamptz not null default now()
);
alter table public.qbo_connection enable row level security;
-- no policies on purpose: only the service role (edge function) touches tokens

create table public.qbo_sync_state (
  id smallint primary key default 1 check (id = 1),
  backfilled boolean not null default false,
  last_cdc timestamptz,
  last_pull_at timestamptz,
  last_error text,
  last_result jsonb
);
alter table public.qbo_sync_state enable row level security;
insert into public.qbo_sync_state (id) values (1);

-- ── mirror columns ──────────────────────────────────────────────────────────
alter table public.invoices
  add column source text not null default 'truxon' check (source in ('truxon', 'qbo')),
  add column qbo_id text unique,
  add column qbo_doc_number text,
  add column qbo_balance numeric,
  add column qbo_synced_at timestamptz;

alter table public.customers add column qbo_id text unique;

-- ── bulk upsert (called by the qbo-sync pull with the service role) ─────────
-- Each element: { qbo_id, doc_number, customer_qbo_id, customer_name,
--                 txn_date, due_date, total, balance, voided }
create or replace function public.qbo_upsert_invoices(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  v_cust bigint;
  v_inv bigint;
  v_ins int := 0;
  v_upd int := 0;
  v_cust_new int := 0;
begin
  -- service only (post-rotation convention: service calls carry no user)
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    -- match customer: by qbo_id, then exact name (case-insensitive), else create
    select id into v_cust from customers where qbo_id = r->>'customer_qbo_id';
    if v_cust is null then
      select id into v_cust from customers
        where lower(company_name) = lower(r->>'customer_name')
        order by id limit 1;
      if v_cust is not null then
        update customers set qbo_id = r->>'customer_qbo_id' where id = v_cust and qbo_id is null;
      else
        insert into customers (company_name, qbo_id)
          values (r->>'customer_name', r->>'customer_qbo_id')
          returning id into v_cust;
        v_cust_new := v_cust_new + 1;
      end if;
    end if;

    select id into v_inv from invoices where qbo_id = r->>'qbo_id';
    if v_inv is null then
      insert into invoices (invoice_number, customer_id, invoice_date, due_date, total,
                            status, source, qbo_id, qbo_doc_number, qbo_balance, qbo_synced_at)
      values (
        'QBO-' || (r->>'doc_number'),
        v_cust,
        (r->>'txn_date')::timestamptz,
        (r->>'due_date')::timestamptz,
        (r->>'total')::numeric,
        case
          when (r->>'voided')::boolean then 'void'
          when (r->>'balance')::numeric = 0 then 'paid'
          else 'sent'
        end::invoice_status,
        'qbo', r->>'qbo_id', r->>'doc_number',
        (r->>'balance')::numeric, now()
      );
      v_ins := v_ins + 1;
    else
      -- update the mirror; flip paid/void from the books, but never resurrect
      -- a void and never touch a Truxon-side draft's numbering
      update invoices set
        total = (r->>'total')::numeric,
        due_date = (r->>'due_date')::timestamptz,
        qbo_doc_number = r->>'doc_number',
        qbo_balance = (r->>'balance')::numeric,
        qbo_synced_at = now(),
        status = case
          when (r->>'voided')::boolean then 'void'::invoice_status
          when status = 'void' then status
          when (r->>'balance')::numeric = 0 then 'paid'::invoice_status
          when status = 'paid' and (r->>'balance')::numeric > 0 then 'sent'::invoice_status
          else status
        end
      where id = v_inv;
      v_upd := v_upd + 1;
    end if;
  end loop;

  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'customers_created', v_cust_new);
end;
$$;
revoke all on function public.qbo_upsert_invoices(jsonb) from public, anon, authenticated;

-- CDC reports hard-deleted/voided invoices as bare {Id}: mark those void.
create or replace function public.qbo_mark_voided(p_qbo_ids jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  update invoices set status = 'void', qbo_balance = 0, qbo_synced_at = now()
    where qbo_id in (select jsonb_array_elements_text(coalesce(p_qbo_ids, '[]'::jsonb)))
      and status <> 'void';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.qbo_mark_voided(jsonb) from public, anon, authenticated;

-- ── status card for the frontend (admin only; never exposes tokens) ─────────
create or replace function public.qbo_status()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return (
    select jsonb_build_object(
      'connected', exists (select 1 from qbo_connection),
      'realm_id', (select realm_id from qbo_connection limit 1),
      'connected_at', (select connected_at from qbo_connection limit 1),
      'backfilled', s.backfilled,
      'last_pull_at', s.last_pull_at,
      'last_error', s.last_error,
      'last_result', s.last_result,
      'qbo_invoices', (select count(*) from invoices where source = 'qbo'),
      'qbo_open_balance', (select coalesce(sum(qbo_balance), 0) from invoices where source = 'qbo' and status = 'sent')
    )
    from qbo_sync_state s where s.id = 1
  );
end;
$$;
revoke all on function public.qbo_status() from public, anon;

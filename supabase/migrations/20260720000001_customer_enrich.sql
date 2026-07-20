-- Customer enrichment from documents.
-- Trux reads each customer's paperwork (setup packets, rate cons, invoices) and
-- fills in the profile fields left blank at import time. This migration is the
-- WRITE CHOKE-POINT: all enrichment writes go through apply_customer_enrichment,
-- which by construction (a) only ever fills EMPTY columns, (b) never touches
-- company_name (the identity), and (c) logs every fill with its source document.
--
--   customer_enrichment_log   per-field provenance (which doc filled which field)
--   customers.enriched_at     last time enrichment filled anything
--   apply_customer_enrichment(customer, fields, source_doc, model) -> int filled

alter table public.customers add column if not exists enriched_at timestamptz;

create table if not exists public.customer_enrichment_log (
  id bigint generated always as identity primary key,
  customer_id bigint not null references public.customers (id) on delete cascade,
  field text not null,
  old_value text,
  new_value text not null,
  source_document_id bigint references public.documents (id) on delete set null,
  model text,
  created_at timestamptz not null default now()
);
create index if not exists customer_enrichment_log_customer_idx on public.customer_enrichment_log (customer_id);
alter table public.customer_enrichment_log enable row level security;

-- Admins read the audit trail; only the service-side RPC writes it.
drop policy if exists customer_enrichment_log_admin_read on public.customer_enrichment_log;
create policy customer_enrichment_log_admin_read on public.customer_enrichment_log
  for select using (public.my_role() = 'admin');

-- ── the single write path ────────────────────────────────────────────────────
-- Fills only-empty, allow-listed columns from p_fields; logs each fill; stamps
-- enriched_at. company_name is deliberately NOT in the allow-list. Called by the
-- customer-enrich edge function with the service role (auth.uid() is null).
create or replace function public.apply_customer_enrichment(
  p_customer_id bigint,
  p_fields jsonb,
  p_source_document_id bigint default null,
  p_model text default null
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_allowed text[] := array[
    'contact_person', 'phone', 'email', 'billing_address',
    'fax', 'toll_free', 'secondary_contact', 'secondary_phone', 'secondary_email', 'notes'
  ];
  v_key text;
  v_val text;
  v_cur text;
  v_filled int := 0;
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  if p_customer_id is null or p_fields is null then
    return 0;
  end if;

  for v_key in select jsonb_object_keys(p_fields) loop
    -- allow-list guard: anything not listed (e.g. company_name) is ignored
    if not (v_key = any (v_allowed)) then
      continue;
    end if;
    v_val := nullif(btrim(coalesce(p_fields ->> v_key, '')), '');
    if v_val is null then
      continue;
    end if;
    -- read the current value dynamically (v_key is allow-listed, so %I is safe)
    execute format('select %I from public.customers where id = $1', v_key)
      into v_cur using p_customer_id;
    -- fill ONLY when currently empty — never overwrite existing data
    if coalesce(btrim(v_cur), '') <> '' then
      continue;
    end if;
    execute format('update public.customers set %I = $1, updated_at = now() where id = $2', v_key)
      using v_val, p_customer_id;
    insert into public.customer_enrichment_log (customer_id, field, old_value, new_value, source_document_id, model)
      values (p_customer_id, v_key, v_cur, v_val, p_source_document_id, p_model);
    v_filled := v_filled + 1;
  end loop;

  if v_filled > 0 then
    update public.customers set enriched_at = now() where id = p_customer_id;
  end if;
  return v_filled;
end;
$$;

revoke all on function public.apply_customer_enrichment(bigint, jsonb, bigint, text) from public, anon, authenticated;

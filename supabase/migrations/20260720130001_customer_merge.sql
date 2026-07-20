-- Customer dedup (owner request 2026-07-20): the QBO invoice pull auto-creates a
-- customer whenever the books spell a name differently, so ~90 brokers exist
-- twice. This adds the machinery to find and merge them — and an MC number
-- column, the broker's real identity, so future dedup (and the FMCSA safety
-- watch) can match on it instead of name spelling.
--
--   customers.mc_number           filled by enrichment from rate cons over time
--   customer_qbo_aliases          merged-away qbo_ids → the kept customer, so the
--                                 30-min sync can never resurrect a merged dupe
--   normalize_company_name()      case/punctuation/suffix-insensitive key
--   duplicate_customer_groups()   report: groups of same-key customers
--   merge_customers(keep, dupe)   repoint everything, fill blanks, delete dupe

alter table public.customers add column if not exists mc_number text not null default '';

create table if not exists public.customer_qbo_aliases (
  qbo_id text primary key,
  customer_id bigint not null references public.customers (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.customer_qbo_aliases enable row level security;
-- no policies: service-side bookkeeping only

-- ── extend the enrichment allow-list with mc_number ─────────────────────────
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
    'fax', 'toll_free', 'secondary_contact', 'secondary_phone', 'secondary_email', 'notes',
    'mc_number'
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

-- ── name normalization ───────────────────────────────────────────────────────
-- 'AM Trans Expedite, L.L.C.' / 'am trans expedite llc' → 'am trans expedite'.
-- Entity suffixes are stripped repeatedly ('co inc' → ''); DBA tails are kept
-- (two brokers can share a DBA — merging on it would be wrong).
create or replace function public.normalize_company_name(p text)
returns text
language plpgsql
immutable
as $$
declare
  v text := lower(coalesce(p, ''));
  v_prev text := '';
begin
  v := regexp_replace(v, '[^a-z0-9&/ ]', ' ', 'g');   -- punctuation → space
  v := regexp_replace(v, '\s+', ' ', 'g');
  v := btrim(v);
  while v <> v_prev loop
    v_prev := v;
    v := btrim(regexp_replace(v,
      '\m(llc|l l c|inc|incorporated|corp|corporation|co|company|ltd|llp|lp)\s*$', '', 'g'));
    v := regexp_replace(v, '\s+', ' ', 'g');
  end loop;
  return v;
end;
$$;

-- ── duplicate report ─────────────────────────────────────────────────────────
create or replace function public.duplicate_customer_groups()
returns table (
  norm_key text,
  members jsonb
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return query
  with keyed as (
    select c.id, c.company_name, c.mc_number, c.qbo_id, c.created_at,
           public.normalize_company_name(c.company_name) as k,
           (select count(*) from loads l where l.customer_id = c.id) as loads,
           (select count(*) from invoices i where i.customer_id = c.id) as invoices
    from customers c
  )
  select k,
         jsonb_agg(jsonb_build_object(
           'id', id, 'company_name', company_name, 'mc_number', mc_number,
           'qbo_id', qbo_id, 'loads', loads, 'invoices', invoices,
           'created_at', created_at) order by loads desc, invoices desc, id)
  from keyed
  where k <> ''
  group by k
  having count(*) > 1;
end;
$$;
revoke all on function public.duplicate_customer_groups() from public, anon;

-- ── merge ────────────────────────────────────────────────────────────────────
-- Everything the dupe owns moves to the keeper; the keeper's blank fields take
-- the dupe's values; the dupe's qbo_id either transfers or lands in the alias
-- ledger; the dupe row is deleted. Admin or service only.
create or replace function public.merge_customers(p_keep bigint, p_dupe bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_keep customers%rowtype;
  v_dupe customers%rowtype;
  v_loads int; v_invoices int; v_docs int; v_filled int := 0; v_n int;
  v_col text;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  if p_keep is null or p_dupe is null or p_keep = p_dupe then
    raise exception 'merge_customers: two distinct customer ids required';
  end if;
  select * into v_keep from customers where id = p_keep for update;
  if not found then raise exception 'keeper % not found', p_keep; end if;
  select * into v_dupe from customers where id = p_dupe for update;
  if not found then raise exception 'duplicate % not found', p_dupe; end if;

  -- repoint ownership
  update loads set customer_id = p_keep where customer_id = p_dupe;
  get diagnostics v_loads = row_count;
  update invoices set customer_id = p_keep where customer_id = p_dupe;
  get diagnostics v_invoices = row_count;
  update documents set entity_id = p_keep where entity_type = 'customer' and entity_id = p_dupe;
  get diagnostics v_docs = row_count;
  update document_embeddings set entity_id = p_keep where entity_type = 'customer' and entity_id = p_dupe;
  update activity_log set entity_id = p_keep where entity_type = 'customer' and entity_id = p_dupe;
  update customer_enrichment_log set customer_id = p_keep where customer_id = p_dupe;

  -- keeper's blanks take the dupe's values (same columns enrichment may fill)
  foreach v_col in array array[
    'contact_person', 'phone', 'email', 'billing_address',
    'fax', 'toll_free', 'secondary_contact', 'secondary_phone', 'secondary_email',
    'notes', 'mc_number'
  ] loop
    execute format(
      'update customers k set %I = d.%I, updated_at = now()
         from customers d
        where k.id = $1 and d.id = $2
          and coalesce(btrim(k.%I), '''') = '''' and coalesce(btrim(d.%I), '''') <> ''''',
      v_col, v_col, v_col, v_col) using p_keep, p_dupe;
    get diagnostics v_n = row_count;
    v_filled := v_filled + v_n;
  end loop;
  update customers set do_not_use = true where id = p_keep and v_dupe.do_not_use;

  -- QBO identity: transfer when the keeper has none; otherwise remember the
  -- dupe's id in the alias ledger so the sync maps it back to the keeper.
  if v_dupe.qbo_id is not null then
    update customers set qbo_id = null where id = p_dupe;
    if v_keep.qbo_id is null then
      update customers set qbo_id = v_dupe.qbo_id where id = p_keep;
    else
      insert into customer_qbo_aliases (qbo_id, customer_id) values (v_dupe.qbo_id, p_keep)
        on conflict (qbo_id) do update set customer_id = excluded.customer_id;
    end if;
  end if;

  delete from customers where id = p_dupe;
  insert into activity_log (entity_type, entity_id, user_id, action, detail)
    values ('customer', p_keep, auth.uid(), 'merge',
            format('merged duplicate "%s" (#%s) into "%s" (#%s): %s loads, %s invoices, %s docs, %s fields filled',
                   v_dupe.company_name, p_dupe, v_keep.company_name, p_keep, v_loads, v_invoices, v_docs, v_filled));

  return jsonb_build_object('kept', p_keep, 'merged', p_dupe,
    'dupe_name', v_dupe.company_name, 'loads', v_loads, 'invoices', v_invoices,
    'documents', v_docs, 'fields_filled', v_filled);
end;
$$;
revoke all on function public.merge_customers(bigint, bigint) from public, anon;

-- ── teach the invoice pull about merged qbo_ids ──────────────────────────────
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
    -- match customer: by qbo_id, then the merged-alias ledger, then exact name
    -- (case-insensitive), else create
    select id into v_cust from customers where qbo_id = r->>'customer_qbo_id';
    if v_cust is null then
      select customer_id into v_cust from customer_qbo_aliases where qbo_id = r->>'customer_qbo_id';
    end if;
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

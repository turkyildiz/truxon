-- USDOT number joins MC number as a customer identity (owner: "mc or dot
-- number, these are unique numbers to each customer"). Some shippers run on a
-- DOT number without an MC; dedup + the future FMCSA watch match on either.

alter table public.customers add column if not exists usdot_number text not null default '';

-- enrichment may fill it (blanks-only, same as everything else)
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
    'mc_number', 'usdot_number'
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

-- merge fills the keeper's blank usdot too (extend the blank-fill column list)
-- and the duplicate report exposes it for the mismatch guard
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
    select c.id, c.company_name, c.mc_number, c.usdot_number, c.qbo_id, c.created_at,
           public.normalize_company_name(c.company_name) as k,
           (select count(*) from loads l where l.customer_id = c.id) as loads,
           (select count(*) from invoices i where i.customer_id = c.id) as invoices
    from customers c
  )
  select k,
         jsonb_agg(jsonb_build_object(
           'id', id, 'company_name', company_name, 'mc_number', mc_number,
           'usdot_number', usdot_number,
           'qbo_id', qbo_id, 'loads', loads, 'invoices', invoices,
           'created_at', created_at) order by loads desc, invoices desc, id)
  from keyed
  where k <> ''
  group by k
  having count(*) > 1;
end;
$$;
revoke all on function public.duplicate_customer_groups() from public, anon;

-- merge_customers: same as 20260720140001, with usdot_number in the blank-fill list
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

  -- repoint ownership (billed loads allowed: customer_id-only via the GUC)
  perform set_config('app.customer_merge', '1', true);
  update loads set customer_id = p_keep where customer_id = p_dupe;
  get diagnostics v_loads = row_count;
  perform set_config('app.customer_merge', '', true);
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
    'notes', 'mc_number', 'usdot_number'
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

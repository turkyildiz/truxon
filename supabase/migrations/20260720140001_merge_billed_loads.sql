-- Customer merges must be able to repoint BILLED loads (the whole point is
-- moving history onto the kept customer), but billed loads are locked against
-- edits. Narrow escape: while merge_customers() runs (transaction-local GUC),
-- an update may pass IF customer_id is the only thing changing. Everything
-- else about a billed load stays locked.

create or replace function public.loads_before_update()
returns trigger language plpgsql as $$
begin
  if current_setting('app.load_rpc', true) = '1' then
    perform public.assert_no_double_booking(new.id, new.driver_id, new.truck_id, new.status);
    return new;
  end if;
  -- merge_customers() repointing ownership: customer_id may change, nothing else
  if current_setting('app.customer_merge', true) = '1'
     and (to_jsonb(new) - 'customer_id' - 'updated_at') = (to_jsonb(old) - 'customer_id' - 'updated_at') then
    return new;
  end if;
  if old.status = 'billed' then
    raise exception 'Billed loads are locked; void the invoice first';
  end if;
  if old.status = 'cancelled' then
    raise exception 'Cancelled loads are locked; un-cancel first';
  end if;
  if new.status is distinct from old.status then
    raise exception 'Use change_load_status() to move a load through the workflow';
  end if;
  if new.invoice_id is distinct from old.invoice_id then
    raise exception 'invoice_id is managed by create_invoice()/void_invoice()';
  end if;
  if new.status = 'pending' and new.driver_id is not null and new.truck_id is not null then
    new.status := 'assigned';
  end if;
  perform public.assert_no_double_booking(new.id, new.driver_id, new.truck_id, new.status);
  return new;
end;
$$;

-- merge_customers: same as 20260720130001, plus the transaction-local flag
-- around the loads repoint.
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

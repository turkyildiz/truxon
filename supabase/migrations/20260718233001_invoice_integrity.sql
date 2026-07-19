-- Invoice integrity: void keeps the invoice as an auditable record instead of
-- hard-deleting it, and numbers come from a real sequence — the old max()+1
-- scan raced under concurrent invoicing and, worse, reissued a voided
-- invoice's number to a different transaction (same bug class already fixed
-- for load numbers in 20260716170001).

-- 1. 'void' becomes a first-class invoice status.
alter type public.invoice_status add value if not exists 'void';

-- 2. Invoice numbers move to a real sequence, started after the highest
--    number already issued (any year) so no existing number is reused.
create sequence if not exists public.invoice_number_seq;

select setval(
  'public.invoice_number_seq',
  greatest(
    (select coalesce(max((regexp_match(invoice_number, '^INV-\d{4}-(\d+)$'))[1]::bigint), 0) from public.invoices),
    1
  ),
  (select exists (select 1 from public.invoices where invoice_number ~ '^INV-\d{4}-\d+$'))
);

create or replace function public.next_invoice_number()
returns text language sql as $$
  select 'INV-' || extract(year from now())::text || '-' || lpad(nextval('public.invoice_number_seq')::text, 4, '0');
$$;

-- 3. Void = soft-cancel. The row stays (status 'void'), its loads revert to
--    completed for re-billing, and the void itself is logged on the invoice.
create or replace function public.void_invoice(p_invoice_id bigint)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  inv public.invoices;
  voided_ids bigint[];
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select * into inv from public.invoices where id = p_invoice_id for update;
  if not found then
    raise exception 'Invoice not found';
  end if;
  if inv.status = 'paid' then
    raise exception 'Cannot void a paid invoice';
  end if;
  if inv.status = 'void' then
    raise exception 'Invoice is already voided';
  end if;

  select coalesce(array_agg(id), '{}') into voided_ids from public.loads where invoice_id = p_invoice_id;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set invoice_id = null, status = 'completed' where id = any(voided_ids);
  perform set_config('app.load_rpc', '', true);

  update public.invoices set status = 'void' where id = p_invoice_id;

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  select 'load', id, auth.uid(), 'status_changed', 'billed → completed (invoice ' || inv.invoice_number || ' voided)'
    from unnest(voided_ids) as id;
  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('invoice', inv.id, auth.uid(), 'voided', inv.invoice_number || ' voided; its loads reverted to completed');
end;
$$;

-- 4. set_invoice_status may not bypass void_invoice in either direction:
--    'void' only via void_invoice (which reverts the loads), and a voided
--    invoice can never be revived.
create or replace function public.set_invoice_status(p_invoice_id bigint, p_status public.invoice_status)
returns public.invoices
language plpgsql security definer set search_path = public
as $$
declare
  inv public.invoices;
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  if p_status = 'void' then
    raise exception 'Use void_invoice() — voiding also reverts the invoice''s loads';
  end if;
  select * into inv from public.invoices where id = p_invoice_id for update;
  if not found then
    raise exception 'Invoice not found';
  end if;
  if inv.status = 'void' then
    raise exception 'Voided invoices are immutable';
  end if;
  update public.invoices set status = p_status where id = p_invoice_id returning * into inv;
  return inv;
end;
$$;

-- 5. Invoices are financial records: nothing deletes them, ever.
create or replace function public.invoices_no_delete()
returns trigger language plpgsql as $$
begin
  raise exception 'Invoices are never deleted — use void_invoice() instead';
end;
$$;

create trigger invoices_no_delete before delete on public.invoices
  for each row execute function public.invoices_no_delete();

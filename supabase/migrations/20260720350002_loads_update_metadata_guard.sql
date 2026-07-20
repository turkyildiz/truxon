-- Metadata-only writes to an active load shouldn't re-validate its driver/truck
-- assignment. loads_before_update re-ran assert_no_double_booking on EVERY rpc
-- update, so a geocode write (or any metadata-only RPC) to an assigned/in_transit
-- load re-checked double-booking — and tripped on legacy loads whose driver was
-- already double-booked (created before that guard existed). Re-validate only
-- when the assignment (driver_id / truck_id / status) actually changes; a write
-- that leaves them untouched can't create a new conflict.
-- Reproduces the current body (20260720140001: cancelled-lock + customer_merge
-- bypass) verbatim; only the rpc-path double-booking check is gated.
create or replace function public.loads_before_update()
returns trigger language plpgsql as $$
begin
  if current_setting('app.load_rpc', true) = '1' then
    if new.driver_id is distinct from old.driver_id
       or new.truck_id is distinct from old.truck_id
       or new.status is distinct from old.status then
      perform public.assert_no_double_booking(new.id, new.driver_id, new.truck_id, new.status);
    end if;
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

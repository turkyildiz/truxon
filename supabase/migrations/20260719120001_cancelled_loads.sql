-- Cancelled loads: brokers cancel booked freight (TONU and friends). Until
-- now the only options were deleting the load (loses history) or leaving it
-- stuck in dispatch forever. 'cancelled' is a terminal, locked status with a
-- reason, reversible only through uncancel_load(). Reports and equipment/
-- double-booking logic filter on explicit status lists, so cancelled loads
-- drop out of revenue, driver pay, dispatch conflicts, and the driver app
-- automatically; cancelling also frees the truck/trailer via
-- sync_equipment_status (active = assigned/in_transit).

alter type public.load_status add value if not exists 'cancelled';

alter table public.loads add column if not exists cancel_reason text not null default '';

-- Cancel: only from the pre-delivery statuses. Delivered freight is real
-- work — that path goes completed → (invoice or not), never cancelled.
create or replace function public.cancel_load(p_load_id bigint, p_reason text default '')
returns public.loads
language plpgsql security definer set search_path = public
as $$
declare
  l public.loads;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select * into l from public.loads where id = p_load_id for update;
  if not found then
    raise exception 'Load not found';
  end if;
  if l.status not in ('pending', 'assigned', 'in_transit') then
    raise exception 'Cannot cancel a % load', l.status;
  end if;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set status = 'cancelled', cancel_reason = btrim(p_reason)
   where id = p_load_id returning * into l;
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('load', p_load_id, auth.uid(), 'status_changed',
          'cancelled' || case when btrim(p_reason) <> '' then ' — ' || btrim(p_reason) else '' end);
  return l;
end;
$$;

-- Un-cancel (corrections): back to pending. Driver/truck stay assigned but
-- the status is re-advanced by the dispatcher, not automatically.
create or replace function public.uncancel_load(p_load_id bigint)
returns public.loads
language plpgsql security definer set search_path = public
as $$
declare
  l public.loads;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select * into l from public.loads where id = p_load_id for update;
  if not found then
    raise exception 'Load not found';
  end if;
  if l.status <> 'cancelled' then
    raise exception 'Load is not cancelled';
  end if;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set status = 'pending', cancel_reason = ''
   where id = p_load_id returning * into l;
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('load', p_load_id, auth.uid(), 'status_changed', 'cancelled → pending (un-cancelled)');
  return l;
end;
$$;

revoke execute on function public.cancel_load(bigint, text) from public, anon;
grant execute on function public.cancel_load(bigint, text) to authenticated;
revoke execute on function public.uncancel_load(bigint) from public, anon;
grant execute on function public.uncancel_load(bigint) to authenticated;

-- change_load_status must not touch cancellation in either direction: with
-- 'cancelled' absent from its status array, array_position returns NULL and
-- the ±1 step check would evaluate to NULL — silently passing (the same
-- fail-open NULL pattern as the anon-guard bug fixed in 20260716250001).
create or replace function public.change_load_status(p_load_id bigint, p_status public.load_status)
returns public.loads
language plpgsql security definer set search_path = public
as $$
declare
  l public.loads;
  statuses public.load_status[] := array['pending','assigned','in_transit','delivered','completed','billed'];
  cur_idx int;
  new_idx int;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  if p_status = 'cancelled' then
    raise exception 'Use cancel_load() to cancel a load';
  end if;

  select * into l from public.loads where id = p_load_id for update;
  if not found then
    raise exception 'Load not found';
  end if;
  if l.status = 'cancelled' then
    raise exception 'Load is cancelled; use uncancel_load() first';
  end if;

  cur_idx := array_position(statuses, l.status);
  new_idx := array_position(statuses, p_status);

  if new_idx = cur_idx then
    return l;
  end if;
  -- Forward one step at a time; backward one step for corrections.
  if new_idx not in (cur_idx + 1, cur_idx - 1) then
    raise exception 'Cannot go from % to %', l.status, p_status;
  end if;
  if p_status = 'assigned' and (l.driver_id is null or l.truck_id is null) then
    raise exception 'Assign a driver and truck first';
  end if;
  if p_status = 'billed' and l.invoice_id is null then
    raise exception 'Generate an invoice to mark a load billed';
  end if;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set status = p_status where id = p_load_id returning * into l;
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('load', p_load_id, auth.uid(), 'status_changed', statuses[cur_idx] || ' → ' || p_status);

  return l;
end;
$$;

-- Cancelled loads are locked like billed ones: edits only through the RPCs.
create or replace function public.loads_before_update()
returns trigger language plpgsql as $$
begin
  if current_setting('app.load_rpc', true) = '1' then
    perform public.assert_no_double_booking(new.id, new.driver_id, new.truck_id, new.status);
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

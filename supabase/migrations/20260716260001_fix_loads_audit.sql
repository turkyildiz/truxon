-- HIGH bug (stress test, 2026-07-16): editing any AUDITED load column (rate,
-- miles, addresses, times, driver/truck/trailer, customer) failed with
-- "malformed array literal: rate". In `changed := changed || 'rate'` the `||`
-- operator resolves to anyarray||anyarray and tries to parse the string 'rate'
-- as an array literal. Load editing through the app was broken end-to-end
-- (status changes and invoicing still worked — they touch un-audited columns).
-- Fix: use array_append, which is unambiguous.

create or replace function public.loads_audit_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  changed text[] := '{}';
begin
  if new.customer_id is distinct from old.customer_id then changed := array_append(changed, 'customer'); end if;
  if new.pickup_address is distinct from old.pickup_address then changed := array_append(changed, 'pickup_address'); end if;
  if new.pickup_time is distinct from old.pickup_time then changed := array_append(changed, 'pickup_time'); end if;
  if new.delivery_address is distinct from old.delivery_address then changed := array_append(changed, 'delivery_address'); end if;
  if new.delivery_time is distinct from old.delivery_time then changed := array_append(changed, 'delivery_time'); end if;
  if new.driver_id is distinct from old.driver_id then changed := array_append(changed, 'driver'); end if;
  if new.truck_id is distinct from old.truck_id then changed := array_append(changed, 'truck'); end if;
  if new.trailer_id is distinct from old.trailer_id then changed := array_append(changed, 'trailer'); end if;
  if new.rate is distinct from old.rate then changed := array_append(changed, 'rate'); end if;
  if new.miles is distinct from old.miles then changed := array_append(changed, 'miles'); end if;
  if array_length(changed, 1) > 0 then
    insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
    values ('load', new.id, auth.uid(), 'updated', 'Changed: ' || array_to_string(changed, ', '));
  end if;
  return new;
end;
$$;

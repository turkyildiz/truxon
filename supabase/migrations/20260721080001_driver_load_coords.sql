-- TABLET DAY — the driver app's load DTO gains stop coordinates so the new
-- in-app map can show the next stop and route to it. Whole function
-- reproduced from 20260717010001 with the four coordinate keys.
create or replace function public.driver_load_dto(p_load_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', l.id,
    'load_number', l.load_number,
    'status', l.status,
    'pickup_address', l.pickup_address,
    'pickup_time', l.pickup_time,
    'delivery_address', l.delivery_address,
    'delivery_time', l.delivery_time,
    'special_terms', l.special_terms,
    'notes', l.notes,
    'miles', l.miles,
    'reference_number', l.reference_number,
    'pickup_number', l.pickup_number,
    'delivery_number', l.delivery_number,
    'customer_name', c.company_name,
    'truck_unit', t.unit_number,
    'trailer_unit', tr.unit_number,
    'driver_name', d.full_name,
    'pickup_lat', l.pickup_lat,
    'pickup_lon', l.pickup_lon,
    'delivery_lat', l.delivery_lat,
    'delivery_lon', l.delivery_lon
  )
  from public.loads l
  join public.customers c on c.id = l.customer_id
  left join public.trucks t on t.id = l.truck_id
  left join public.trailers tr on tr.id = l.trailer_id
  join public.drivers d on d.id = l.driver_id
  where l.id = p_load_id;
$$;

revoke all on function public.driver_load_dto(bigint) from public;
revoke all on function public.driver_load_dto(bigint) from anon, authenticated;

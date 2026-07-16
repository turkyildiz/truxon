-- Dispatch improvements (owner feedback 2026-07-16):
-- 1. Load numbers move to a real sequence — the old max()+1 scan could hand
--    two simultaneous dispatchers the same number (one insert then failed on
--    the unique constraint).
-- 2. Broker paperwork identifiers on every load: the broker's PRO/load
--    number, the pickup (PU#) number, and the delivery/confirmation number.
--    Global search and the Loads search box match the broker number too,
--    since that's the number a broker reads out on the phone.

-- ---------- collision-free load numbers ----------

create sequence if not exists public.load_number_seq;

-- Start the sequence after the highest number already issued (any year).
select setval(
  'public.load_number_seq',
  greatest(
    (select coalesce(max((regexp_match(load_number, '^LD-\d{4}-(\d+)$'))[1]::bigint), 0) from public.loads),
    1
  ),
  (select exists (select 1 from public.loads where load_number ~ '^LD-\d{4}-\d+$'))
);

create or replace function public.next_load_number()
returns text language sql as $$
  select 'LD-' || extract(year from now())::text || '-' || lpad(nextval('public.load_number_seq')::text, 4, '0');
$$;

-- ---------- broker paperwork identifiers ----------

alter table public.loads
  add column if not exists reference_number text not null default '',
  add column if not exists pickup_number text not null default '',
  add column if not exists delivery_number text not null default '';

comment on column public.loads.reference_number is 'Broker''s PRO/load/order number from the rate confirmation';
comment on column public.loads.pickup_number is 'PU number the driver gives at the shipper';
comment on column public.loads.delivery_number is 'Delivery/confirmation number for the receiver';

-- ---------- search by broker number ----------
-- (Recreated from 20260716150001 — role gate unchanged, loads match adds
-- reference_number.)

create or replace function public.global_search(q text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return jsonb_build_object(
    'loads', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'label', l.load_number || ' — ' || c.company_name))
                from (select * from public.loads
                       where load_number ilike '%' || q || '%'
                          or reference_number ilike '%' || q || '%'
                          or pickup_address ilike '%' || q || '%'
                          or delivery_address ilike '%' || q || '%' limit 10) l
                join public.customers c on c.id = l.customer_id), '[]'::jsonb),
    'customers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', company_name))
                    from (select id, company_name from public.customers where company_name ilike '%' || q || '%' limit 10) c), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', full_name))
                  from (select id, full_name from public.drivers where full_name ilike '%' || q || '%' limit 10) d), '[]'::jsonb),
    'trucks', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', unit_number))
                 from (select id, unit_number from public.trucks where unit_number ilike '%' || q || '%' limit 10) t), '[]'::jsonb)
  );
end;
$$;

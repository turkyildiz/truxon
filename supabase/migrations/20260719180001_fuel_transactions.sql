-- Fuel-card integration (AtoB). A scheduled job pulls the transactions CSV
-- from AtoB and feeds it here; each row is keyed by AtoB's own UUID so the
-- import is idempotent — a pending charge that later settles (gaining
-- gallons / net-of-discount) re-imports as an UPDATE on the same UUID, never a
-- duplicate. Rows are matched to a Truxon truck by AtoB's "Vehicle Name"
-- (which is the unit number) and to a driver by name; both are best-effort and
-- nullable. Feeds per-truck fuel cost, weekly accounting, and IFTA by state.

create table if not exists public.fuel_transactions (
  id bigint generated always as identity primary key,
  uuid text not null unique,                       -- AtoB transaction UUID (dedup key)
  transaction_time timestamptz not null,           -- "Transaction Date (GMT)"
  posted_date timestamptz,                          -- null until settled
  status text not null default '',                 -- Pending / Approved / Declined / …
  card_last_four text,
  merchant text not null default '',
  merchant_city text not null default '',
  merchant_state text not null default '',          -- IFTA jurisdiction
  merchant_zip text not null default '',
  merchant_category text not null default '',
  amount numeric(12,2) not null default 0,          -- gross "Amount"
  net_of_discount numeric(12,2),                    -- null until settled
  discount numeric(12,2),
  fuel_type text not null default '',               -- "Type" (Diesel, …)
  gallons numeric(10,3),
  price_per_gallon numeric(10,4),
  description text not null default '',
  prompted_odometer bigint,
  telematics_odometer bigint,
  tag text not null default '',
  driver_name text not null default '',             -- as reported by AtoB
  vehicle_name text not null default '',            -- AtoB "Vehicle Name" = unit number
  vin text not null default '',
  truck_id bigint references public.trucks (id),    -- matched, nullable
  driver_id bigint references public.drivers (id),  -- matched, nullable
  raw jsonb not null default '{}',                  -- full source row for audit
  imported_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists fuel_tx_time_idx on public.fuel_transactions (transaction_time desc);
create index if not exists fuel_tx_truck_idx on public.fuel_transactions (truck_id, transaction_time desc);
create index if not exists fuel_tx_state_idx on public.fuel_transactions (merchant_state);
create index if not exists fuel_tx_unmatched_idx on public.fuel_transactions (vehicle_name) where truck_id is null;

alter table public.fuel_transactions enable row level security;

-- Fuel spend is company financial data: admin/accountant/dispatcher may read
-- it in-app (same gate as invoicing/reporting). Drivers and maintenance never
-- see it. All writes go through the SECURITY DEFINER importer (service role),
-- so there is no client write policy.
drop policy if exists fuel_tx_staff_read on public.fuel_transactions;
create policy fuel_tx_staff_read on public.fuel_transactions
  for select to authenticated
  using (public.my_role() in ('admin', 'accountant', 'dispatcher'));

-- ---------- idempotent importer ----------
-- Takes an array of already-parsed rows (the edge function does the CSV
-- cleanup: strips $/commas from money, the "**** " from the card, parses the
-- GMT dates to ISO). Upserts on uuid; re-matches truck/driver each time so a
-- later-added VIN or a renamed truck is picked up on the next import.
create or replace function public.import_fuel_transactions(p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  before_count int;
  after_count int;
  affected int;
begin
  -- Callable by the service role (edge function) or an admin doing a manual load.
  if auth.role() <> 'service_role' and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'p_rows must be a JSON array';
  end if;

  select count(*) into before_count from public.fuel_transactions;

  with incoming as (
    select * from jsonb_to_recordset(p_rows) as x(
      uuid text, transaction_time timestamptz, posted_date timestamptz, status text,
      card_last_four text, merchant text, merchant_city text, merchant_state text,
      merchant_zip text, merchant_category text, amount numeric, net_of_discount numeric,
      discount numeric, fuel_type text, gallons numeric, price_per_gallon numeric,
      description text, prompted_odometer bigint, telematics_odometer bigint,
      tag text, driver_name text, vehicle_name text, vin text, raw jsonb
    )
  ),
  resolved as (
    select i.*,
      -- Match a truck by VIN when present, else by unit number = Vehicle Name.
      coalesce(
        (select t.id from public.trucks t where t.vin <> '' and t.vin = i.vin),
        (select t.id from public.trucks t where t.unit_number = i.vehicle_name)
      ) as truck_id,
      (select d.id from public.drivers d where d.full_name = i.driver_name) as driver_id
    from incoming i
  )
  insert into public.fuel_transactions (
    uuid, transaction_time, posted_date, status, card_last_four, merchant,
    merchant_city, merchant_state, merchant_zip, merchant_category, amount,
    net_of_discount, discount, fuel_type, gallons, price_per_gallon, description,
    prompted_odometer, telematics_odometer, tag, driver_name, vehicle_name, vin,
    truck_id, driver_id, raw, updated_at
  )
  select
    uuid, transaction_time, posted_date, coalesce(status,''), card_last_four, coalesce(merchant,''),
    coalesce(merchant_city,''), coalesce(merchant_state,''), coalesce(merchant_zip,''), coalesce(merchant_category,''),
    coalesce(amount,0), net_of_discount, discount, coalesce(fuel_type,''), gallons, price_per_gallon, coalesce(description,''),
    prompted_odometer, telematics_odometer, coalesce(tag,''), coalesce(driver_name,''), coalesce(vehicle_name,''), coalesce(vin,''),
    truck_id, driver_id, coalesce(raw,'{}'::jsonb), now()
  from resolved
  on conflict (uuid) do update set
    transaction_time = excluded.transaction_time,
    posted_date = excluded.posted_date,
    status = excluded.status,
    amount = excluded.amount,
    net_of_discount = excluded.net_of_discount,
    discount = excluded.discount,
    fuel_type = excluded.fuel_type,
    gallons = excluded.gallons,
    price_per_gallon = excluded.price_per_gallon,
    description = excluded.description,
    prompted_odometer = excluded.prompted_odometer,
    telematics_odometer = excluded.telematics_odometer,
    tag = excluded.tag,
    driver_name = excluded.driver_name,
    vehicle_name = excluded.vehicle_name,
    vin = excluded.vin,
    truck_id = excluded.truck_id,
    driver_id = excluded.driver_id,
    raw = excluded.raw,
    updated_at = now();

  get diagnostics affected = row_count;
  select count(*) into after_count from public.fuel_transactions;

  return jsonb_build_object(
    'received', jsonb_array_length(p_rows),
    'inserted', after_count - before_count,
    'updated', affected - (after_count - before_count),
    'unmatched_trucks', (select count(*) from public.fuel_transactions where truck_id is null)
  );
end;
$$;

revoke execute on function public.import_fuel_transactions(jsonb) from public, anon;
grant execute on function public.import_fuel_transactions(jsonb) to authenticated, service_role;
grant select, insert, update on public.fuel_transactions to service_role;

-- ---------- reporting ----------
-- Per-truck fuel spend + gallons over a window (settled or pending both count;
-- caller can filter). Feeds the accounting screen's per-truck cost.
create or replace function public.fuel_by_truck(p_start timestamptz, p_end timestamptz)
returns table (truck_id bigint, unit_number text, transactions int, gallons numeric, spend numeric)
language sql stable security definer set search_path = public
as $$
  select f.truck_id, t.unit_number,
         count(*)::int, coalesce(sum(f.gallons),0), coalesce(sum(coalesce(f.net_of_discount, f.amount)),0)
    from public.fuel_transactions f
    left join public.trucks t on t.id = f.truck_id
   where public.my_role() in ('admin','accountant','dispatcher')
     and f.transaction_time >= p_start and f.transaction_time < p_end
     and f.status <> 'Declined'
   group by f.truck_id, t.unit_number
   order by 5 desc;   -- spend
$$;

-- IFTA: taxable gallons + spend by jurisdiction (merchant state) over a window.
create or replace function public.fuel_ifta_summary(p_start timestamptz, p_end timestamptz)
returns table (jurisdiction text, transactions int, gallons numeric, spend numeric)
language sql stable security definer set search_path = public
as $$
  select f.merchant_state,
         count(*)::int, coalesce(sum(f.gallons),0), coalesce(sum(coalesce(f.net_of_discount, f.amount)),0)
    from public.fuel_transactions f
   where public.my_role() in ('admin','accountant','dispatcher')
     and f.transaction_time >= p_start and f.transaction_time < p_end
     and f.status <> 'Declined'
     and coalesce(f.gallons,0) > 0
   group by f.merchant_state
   order by 3 desc;   -- gallons
$$;

revoke execute on function public.fuel_by_truck(timestamptz, timestamptz) from public, anon;
revoke execute on function public.fuel_ifta_summary(timestamptz, timestamptz) from public, anon;
grant execute on function public.fuel_by_truck(timestamptz, timestamptz) to authenticated;
grant execute on function public.fuel_ifta_summary(timestamptz, timestamptz) to authenticated;

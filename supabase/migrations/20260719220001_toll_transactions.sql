-- Toll integration (PrePass). A scheduled serverless sync (toll-sync edge
-- function + pg_cron) pulls toll transactions from the PrePass Toll Transaction
-- API and feeds them here. Each row is keyed by PrePass's tollId so the import
-- is idempotent. Rows are matched to a Truxon truck by PrePass "vehicleNumber"
-- (the customer's unit number). Feeds per-truck toll cost, tolls by agency/
-- jurisdiction, and violation flags. Mirrors the fuel_transactions design.

create table if not exists public.toll_transactions (
  id bigint generated always as identity primary key,
  toll_id text not null unique,                     -- PrePass tollId (dedup key)
  account_number bigint,
  account_name text not null default '',
  bill_to_account_number bigint,
  bill_to_account_name text not null default '',
  post_date_time timestamptz,                       -- when it posted to the account
  invoice_date_time timestamptz,
  exit_date_time timestamptz,                       -- when the toll occurred (local)
  entry_date_time timestamptz,
  device_number text not null default '',           -- transponder / sticker
  vehicle_number text not null default '',          -- PrePass vehicle id = unit number
  plate_number text not null default '',
  toll_agency_name text not null default '',
  toll_agency_state text not null default '',        -- jurisdiction
  billing_agency_code text not null default '',
  entry_plaza_code text not null default '',
  entry_plaza_name text not null default '',
  exit_plaza_code text not null default '',
  exit_plaza_name text not null default '',
  read_type text not null default '',                -- Plate / Device
  toll_class text not null default '',
  toll_charge numeric(12,2) not null default 0,
  toll_category text not null default '',            -- Normal / Violation
  dispute_status text not null default '',
  truck_id bigint references public.trucks (id),      -- matched, nullable
  raw jsonb not null default '{}',
  imported_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists toll_tx_time_idx on public.toll_transactions (coalesce(post_date_time, exit_date_time) desc);
create index if not exists toll_tx_truck_idx on public.toll_transactions (truck_id);
create index if not exists toll_tx_agency_idx on public.toll_transactions (toll_agency_state);
create index if not exists toll_tx_violation_idx on public.toll_transactions (toll_category) where toll_category = 'Violation';

alter table public.toll_transactions enable row level security;

-- Financial data: admin/accountant/dispatcher read (same gate as fuel/invoices).
drop policy if exists toll_tx_staff_read on public.toll_transactions;
create policy toll_tx_staff_read on public.toll_transactions
  for select to authenticated
  using (public.my_role() in ('admin', 'accountant', 'dispatcher'));

-- ---------- idempotent importer ----------
-- Takes already-parsed rows (the toll-sync function does the JSON→typed
-- cleanup: tollCharge string→numeric, date strings→timestamptz). Upserts on
-- toll_id and re-matches the truck each time.
create or replace function public.import_toll_transactions(p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  before_count int;
  after_count int;
  affected int;
begin
  if auth.role() <> 'service_role' and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'p_rows must be a JSON array';
  end if;

  select count(*) into before_count from public.toll_transactions;

  with incoming as (
    select * from jsonb_to_recordset(p_rows) as x(
      toll_id text, account_number bigint, account_name text, bill_to_account_number bigint,
      bill_to_account_name text, post_date_time timestamptz, invoice_date_time timestamptz,
      exit_date_time timestamptz, entry_date_time timestamptz, device_number text,
      vehicle_number text, plate_number text, toll_agency_name text, toll_agency_state text,
      billing_agency_code text, entry_plaza_code text, entry_plaza_name text, exit_plaza_code text,
      exit_plaza_name text, read_type text, toll_class text, toll_charge numeric,
      toll_category text, dispute_status text, raw jsonb
    )
  ),
  resolved as (
    select i.*,
      (select t.id from public.trucks t where t.unit_number = i.vehicle_number) as truck_id
    from incoming i
  )
  insert into public.toll_transactions (
    toll_id, account_number, account_name, bill_to_account_number, bill_to_account_name,
    post_date_time, invoice_date_time, exit_date_time, entry_date_time, device_number,
    vehicle_number, plate_number, toll_agency_name, toll_agency_state, billing_agency_code,
    entry_plaza_code, entry_plaza_name, exit_plaza_code, exit_plaza_name, read_type,
    toll_class, toll_charge, toll_category, dispute_status, truck_id, raw, updated_at
  )
  select
    toll_id, account_number, coalesce(account_name,''), bill_to_account_number, coalesce(bill_to_account_name,''),
    post_date_time, invoice_date_time, exit_date_time, entry_date_time, coalesce(device_number,''),
    coalesce(vehicle_number,''), coalesce(plate_number,''), coalesce(toll_agency_name,''), coalesce(toll_agency_state,''), coalesce(billing_agency_code,''),
    coalesce(entry_plaza_code,''), coalesce(entry_plaza_name,''), coalesce(exit_plaza_code,''), coalesce(exit_plaza_name,''), coalesce(read_type,''),
    coalesce(toll_class,''), coalesce(toll_charge,0), coalesce(toll_category,''), coalesce(dispute_status,''), truck_id, coalesce(raw,'{}'::jsonb), now()
  from resolved
  on conflict (toll_id) do update set
    account_number = excluded.account_number, account_name = excluded.account_name,
    bill_to_account_number = excluded.bill_to_account_number, bill_to_account_name = excluded.bill_to_account_name,
    post_date_time = excluded.post_date_time, invoice_date_time = excluded.invoice_date_time,
    exit_date_time = excluded.exit_date_time, entry_date_time = excluded.entry_date_time,
    device_number = excluded.device_number, vehicle_number = excluded.vehicle_number,
    plate_number = excluded.plate_number, toll_agency_name = excluded.toll_agency_name,
    toll_agency_state = excluded.toll_agency_state, billing_agency_code = excluded.billing_agency_code,
    entry_plaza_code = excluded.entry_plaza_code, entry_plaza_name = excluded.entry_plaza_name,
    exit_plaza_code = excluded.exit_plaza_code, exit_plaza_name = excluded.exit_plaza_name,
    read_type = excluded.read_type, toll_class = excluded.toll_class, toll_charge = excluded.toll_charge,
    toll_category = excluded.toll_category, dispute_status = excluded.dispute_status,
    truck_id = excluded.truck_id, raw = excluded.raw, updated_at = now();

  get diagnostics affected = row_count;
  select count(*) into after_count from public.toll_transactions;

  return jsonb_build_object(
    'received', jsonb_array_length(p_rows),
    'inserted', after_count - before_count,
    'updated', affected - (after_count - before_count),
    'unmatched_trucks', (select count(*) from public.toll_transactions where truck_id is null),
    'violations', (select count(*) from public.toll_transactions where toll_category = 'Violation')
  );
end;
$$;

revoke execute on function public.import_toll_transactions(jsonb) from public, anon;
grant execute on function public.import_toll_transactions(jsonb) to authenticated, service_role;
grant select, insert, update on public.toll_transactions to service_role;

-- ---------- reporting ----------
create or replace function public.toll_by_truck(p_start timestamptz, p_end timestamptz)
returns table (truck_id bigint, unit_number text, tolls int, violations int, spend numeric)
language sql stable security definer set search_path = public
as $$
  select f.truck_id, t.unit_number,
         count(*)::int, count(*) filter (where f.toll_category = 'Violation')::int,
         coalesce(sum(f.toll_charge),0)
    from public.toll_transactions f
    left join public.trucks t on t.id = f.truck_id
   where public.my_role() in ('admin','accountant','dispatcher')
     and coalesce(f.post_date_time, f.exit_date_time) >= p_start
     and coalesce(f.post_date_time, f.exit_date_time) < p_end
   group by f.truck_id, t.unit_number
   order by 5 desc;   -- spend
$$;

-- Tolls by jurisdiction (agency state) over a window.
create or replace function public.toll_by_agency(p_start timestamptz, p_end timestamptz)
returns table (jurisdiction text, agency text, tolls int, spend numeric)
language sql stable security definer set search_path = public
as $$
  select f.toll_agency_state, f.toll_agency_name,
         count(*)::int, coalesce(sum(f.toll_charge),0)
    from public.toll_transactions f
   where public.my_role() in ('admin','accountant','dispatcher')
     and coalesce(f.post_date_time, f.exit_date_time) >= p_start
     and coalesce(f.post_date_time, f.exit_date_time) < p_end
   group by f.toll_agency_state, f.toll_agency_name
   order by 4 desc;   -- spend
$$;

revoke execute on function public.toll_by_truck(timestamptz, timestamptz) from public, anon;
revoke execute on function public.toll_by_agency(timestamptz, timestamptz) from public, anon;
grant execute on function public.toll_by_truck(timestamptz, timestamptz) to authenticated;
grant execute on function public.toll_by_agency(timestamptz, timestamptz) to authenticated;

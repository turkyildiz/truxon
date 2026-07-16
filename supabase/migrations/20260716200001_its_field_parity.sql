-- Field parity with ITS Dispatch (owner rule 2026-07-16: any field that is
-- actually filled in the old system gets a home in Truxon). Fill-rate scan
-- of the migrated data drove this list — empty ITS fields were skipped.

alter table public.loads
  add column if not exists equipment_type text not null default '',  -- "53' Van", Reefer…
  add column if not exists empty_miles numeric(8,1) not null default 0;

alter table public.customers
  add column if not exists fax text not null default '',
  add column if not exists toll_free text not null default '',
  add column if not exists secondary_contact text not null default '',
  add column if not exists secondary_phone text not null default '',
  add column if not exists secondary_email text not null default '';

alter table public.drivers
  add column if not exists address text not null default '',
  add column if not exists city text not null default '',
  add column if not exists state text not null default '',
  add column if not exists pay_per_empty_mile numeric(6,3) not null default 0;

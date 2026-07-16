-- Fields needed to carry over ITS Dispatch data without loss
-- (2026-07-16 migration): driver contact info and free-form notes;
-- equipment plate numbers. UI exposure tracked separately.

alter table public.drivers
  add column if not exists phone text not null default '',
  add column if not exists email text not null default '',
  add column if not exists notes text not null default '';

alter table public.trucks
  add column if not exists plate_number text not null default '',
  add column if not exists plate_expiry date,
  add column if not exists notes text not null default '';

alter table public.trailers
  add column if not exists plate_number text not null default '',
  add column if not exists plate_expiry date,
  add column if not exists notes text not null default '';

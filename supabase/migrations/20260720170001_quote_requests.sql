-- Public quote requests from the truxon.com landing page (owner request via
-- crew feedback): origin/destination each accept City+State OR Zip — either
-- one satisfies the requirement, enforced right here in the table.

create table if not exists public.quote_requests (
  id bigint generated always as identity primary key,
  contact_name text not null,
  company text not null default '',
  email text not null default '',
  phone text not null default '',
  origin_city text not null default '',
  origin_state text not null default '',
  origin_zip text not null default '',
  dest_city text not null default '',
  dest_state text not null default '',
  dest_zip text not null default '',
  equipment text not null default '',
  pickup_date date,
  notes text not null default '',
  status text not null default 'new' check (status in ('new', 'quoted', 'won', 'lost', 'spam')),
  created_at timestamptz not null default now(),
  -- the either/or rule: City+State or Zip, per end
  constraint quote_origin_locatable check (
    origin_zip <> '' or (origin_city <> '' and origin_state <> '')
  ),
  constraint quote_dest_locatable check (
    dest_zip <> '' or (dest_city <> '' and dest_state <> '')
  ),
  -- some way to reach them back
  constraint quote_reachable check (email <> '' or phone <> '')
);

alter table public.quote_requests enable row level security;
-- staff read + work the queue; inserts come only from the edge (service role)
drop policy if exists quote_requests_staff_read on public.quote_requests;
create policy quote_requests_staff_read on public.quote_requests
  for select using (public.my_role() in ('admin', 'dispatcher'));
drop policy if exists quote_requests_staff_update on public.quote_requests;
create policy quote_requests_staff_update on public.quote_requests
  for update using (public.my_role() in ('admin', 'dispatcher'))
  with check (public.my_role() in ('admin', 'dispatcher'));

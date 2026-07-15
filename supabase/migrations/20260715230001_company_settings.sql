-- Company settings: single-row table for invoice branding and company info.

create table public.company_settings (
  id int primary key default 1 check (id = 1),  -- enforce single row
  company_name text not null default 'Truxon Logistics',
  address text not null default '',
  phone text not null default '',
  email text not null default '',
  mc_number text not null default '',
  logo_path text not null default '',  -- storage path in 'documents' bucket
  updated_at timestamptz not null default now()
);

insert into public.company_settings (id) values (1);

create trigger company_settings_touch before update on public.company_settings
  for each row execute function public.touch_updated_at();

alter table public.company_settings enable row level security;

create policy company_settings_read on public.company_settings
  for select to authenticated using (true);

create policy company_settings_admin_update on public.company_settings
  for update to authenticated
  using (public.my_role() = 'admin')
  with check (public.my_role() = 'admin');

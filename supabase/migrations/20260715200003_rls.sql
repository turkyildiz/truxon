-- Truxon TMS — row-level security.
-- Mirrors the RBAC matrix: admin everywhere; dispatcher = operations;
-- accountant = money + read ops; maintenance = fleet + repairs only.

alter table public.profiles enable row level security;
alter table public.customers enable row level security;
alter table public.drivers enable row level security;
alter table public.trucks enable row level security;
alter table public.trailers enable row level security;
alter table public.maintenance_records enable row level security;
alter table public.loads enable row level security;
alter table public.invoices enable row level security;
alter table public.documents enable row level security;
alter table public.activity_log enable row level security;

-- ---------- profiles ----------
-- Everyone can read profiles (needed to show "who did what" in activity);
-- only admins change them (user creation runs through the admin edge
-- function with the service role, which bypasses RLS).

create policy profiles_select on public.profiles
  for select to authenticated using (true);

create policy profiles_admin_update on public.profiles
  for update to authenticated
  using (public.my_role() = 'admin')
  with check (public.my_role() = 'admin');

-- ---------- customers ----------

create policy customers_select on public.customers
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create policy customers_insert on public.customers
  for insert to authenticated
  with check (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create policy customers_update on public.customers
  for update to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'))
  with check (public.my_role() in ('admin', 'dispatcher', 'accountant'));

-- ---------- drivers ----------

create policy drivers_select on public.drivers
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create policy drivers_insert on public.drivers
  for insert to authenticated
  with check (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create policy drivers_update on public.drivers
  for update to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'))
  with check (public.my_role() in ('admin', 'dispatcher', 'accountant'));

-- ---------- trucks & trailers ----------

create policy trucks_select on public.trucks
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant', 'maintenance'));

create policy trucks_insert on public.trucks
  for insert to authenticated
  with check (public.my_role() in ('admin', 'dispatcher', 'maintenance'));

create policy trucks_update on public.trucks
  for update to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'maintenance'))
  with check (public.my_role() in ('admin', 'dispatcher', 'maintenance'));

create policy trailers_select on public.trailers
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant', 'maintenance'));

create policy trailers_insert on public.trailers
  for insert to authenticated
  with check (public.my_role() in ('admin', 'dispatcher', 'maintenance'));

create policy trailers_update on public.trailers
  for update to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'maintenance'))
  with check (public.my_role() in ('admin', 'dispatcher', 'maintenance'));

-- ---------- maintenance ----------

create policy maintenance_select on public.maintenance_records
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant', 'maintenance'));

create policy maintenance_insert on public.maintenance_records
  for insert to authenticated
  with check (public.my_role() in ('admin', 'dispatcher', 'maintenance'));

create policy maintenance_update on public.maintenance_records
  for update to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'maintenance'))
  with check (public.my_role() in ('admin', 'dispatcher', 'maintenance'));

-- ---------- loads ----------

create policy loads_select on public.loads
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create policy loads_insert on public.loads
  for insert to authenticated
  with check (public.my_role() in ('admin', 'dispatcher'));

create policy loads_update on public.loads
  for update to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'))
  with check (public.my_role() in ('admin', 'dispatcher', 'accountant'));

-- ---------- invoices ----------

create policy invoices_select on public.invoices
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));
-- writes happen only through the security-definer RPCs

-- ---------- documents & activity ----------
-- Any authenticated staff member may read/attach documents and notes;
-- deletes restricted to admin + dispatcher.

create policy documents_select on public.documents
  for select to authenticated using (auth.uid() is not null);

create policy documents_insert on public.documents
  for insert to authenticated with check (uploaded_by = auth.uid());

create policy documents_delete on public.documents
  for delete to authenticated
  using (public.my_role() in ('admin', 'dispatcher'));

create policy activity_select on public.activity_log
  for select to authenticated using (auth.uid() is not null);

-- Users may add notes as themselves; system entries come from
-- security-definer triggers/RPCs which bypass RLS.
create policy activity_insert_notes on public.activity_log
  for insert to authenticated
  with check (action = 'note' and user_id = auth.uid());

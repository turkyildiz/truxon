-- MEDIUM finding (stress test, 2026-07-16): with RLS on and no DELETE policy,
-- even an admin's delete silently affects 0 rows — erroneous/test records
-- can't be removed through the app. Give admins a DELETE policy on the core
-- records. Referential integrity still protects against orphaning (deleting a
-- customer/driver/truck still in use by a load fails the FK, as intended);
-- deleting a load cascades its load_stops. Non-admin roles keep soft-delete
-- (is_active / status) as the normal path.

create policy loads_admin_delete on public.loads
  for delete to authenticated using (public.my_role() = 'admin');

create policy customers_admin_delete on public.customers
  for delete to authenticated using (public.my_role() = 'admin');

create policy drivers_admin_delete on public.drivers
  for delete to authenticated using (public.my_role() = 'admin');

create policy trucks_admin_delete on public.trucks
  for delete to authenticated using (public.my_role() = 'admin');

create policy trailers_admin_delete on public.trailers
  for delete to authenticated using (public.my_role() = 'admin');

create policy maintenance_admin_delete on public.maintenance_records
  for delete to authenticated using (public.my_role() = 'admin');

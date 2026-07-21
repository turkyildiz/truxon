-- GT-06 — profiles SELECT was open to every authenticated role, so any driver
-- login could read the full staff roster (names, usernames, roles). Narrow to
-- self + office roles: both apps load only their own row for auth, and every
-- surface that lists profiles (dispatch linking, Drive share owners, admin
-- users) is office-only. my_role() is SECURITY DEFINER so no RLS recursion.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (
    id = auth.uid()
    or public.my_role() in ('admin', 'dispatcher', 'accountant')
  );

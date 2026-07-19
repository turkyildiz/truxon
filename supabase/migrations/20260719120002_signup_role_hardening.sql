-- Never mint an admin from signup metadata. Safe today only because signup
-- is disabled; if it were ever enabled, self-registration with
-- {"role": "admin"} would auto-create an admin. Admins are now created by
-- the admin-users edge function promoting the profile AFTER creation via the
-- service role — the trigger itself grants at most dispatcher.

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  requested text := new.raw_user_meta_data ->> 'role';
  granted public.user_role;
begin
  -- 'admin' is refused, unknown/absent falls back — a bare cast would throw
  -- on garbage metadata and block the auth user's creation entirely.
  granted := case
    when requested in ('dispatcher', 'driver', 'accountant', 'maintenance') then requested::public.user_role
    else 'dispatcher'::public.user_role
  end;
  insert into public.profiles (id, username, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    granted
  );
  return new;
end;
$$;

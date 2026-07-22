-- Code review 2026-07-21 — SQL LOW findings.
-- All three are latent (signup disabled, drivers don't reach trux_query UI,
-- admin deletes are rare) but cheap to close and reduce blast radius.

-- LOW: handle_new_user() minted 'dispatcher' by default — not least privilege.
-- Default the unknown/absent case to 'driver'; a real dispatcher/accountant is
-- still honored from vetted metadata, and admin is still refused.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  requested text := new.raw_user_meta_data ->> 'role';
  granted public.user_role;
begin
  granted := case
    when requested in ('dispatcher', 'driver', 'accountant', 'maintenance') then requested::public.user_role
    else 'driver'::public.user_role
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

-- LOW: trux_query (ad-hoc read-only SQL) was reachable by every authenticated
-- user incl. drivers — a schema-enumeration surface. Gate it to office roles.
-- Bounds are unchanged (INVOKER + read-only + RLS); this just narrows who can
-- open the console at all.
create or replace function public.trux_query(p_sql text)
returns jsonb
language plpgsql security invoker
as $$
declare
  q text := btrim(p_sql);
  v_role public.user_role := public.my_role();
  result jsonb;
begin
  if v_role is null then
    raise exception 'Not authenticated';
  end if;
  if v_role = 'driver' then
    raise exception 'Not enough permissions';
  end if;
  if q !~* '^\s*(select|with)\y' then
    raise exception 'Only SELECT queries are allowed';
  end if;
  if q ~* '\m(insert|update|delete|truncate|drop|alter|create|grant|revoke|copy|vacuum|call|do|set|reset|listen|notify|refresh)\M' then
    raise exception 'Query contains a disallowed keyword — read-only SELECT only';
  end if;
  if q like '%;%' then
    raise exception 'Multiple statements are not allowed';
  end if;

  perform set_config('statement_timeout', '4000', true);
  perform set_config('transaction_read_only', 'on', true);

  execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (select * from (%s) q limit 200) t', q)
    into result;
  return result;
end;
$$;

-- LOW: protect_last_admin only covered UPDATE — a DELETE of the sole active
-- admin slipped past it. Add a BEFORE DELETE guard reusing the same count check.
create or replace function public.protect_last_admin_delete()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.role = 'admin' and old.is_active
     and (select count(*) from public.profiles
           where role = 'admin' and is_active and id <> old.id) = 0 then
    raise exception 'Cannot delete the last active admin';
  end if;
  return old;
end;
$$;
drop trigger if exists profiles_protect_last_admin_delete on public.profiles;
create trigger profiles_protect_last_admin_delete
  before delete on public.profiles
  for each row execute function public.protect_last_admin_delete();

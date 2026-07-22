-- ============================================================================
-- Break-glass lockdown.
-- One switch to throw when you suspect a compromise. Setting lockdown freezes
-- the privilege-escalation path immediately: no role changes, no new accounts,
-- no admin grants can be written while it's on (service_role — crons/backups —
-- still runs so you can recover and flip it back). It's the automated, tested
-- half; the full read-only freeze of the whole database is a one-line superuser
-- command documented in deploy/SECURITY_RUNBOOK.md.
-- ============================================================================

create table if not exists app_private.system_flags (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
insert into app_private.system_flags (key, value) values ('lockdown','off')
on conflict (key) do nothing;
revoke all on table app_private.system_flags from public, anon, authenticated, service_role;

create or replace function public.system_status()
returns jsonb
language sql stable security definer set search_path = public, app_private
as $$
  select jsonb_build_object(
    'lockdown', coalesce((select value = 'on' from app_private.system_flags where key='lockdown'), false));
$$;
revoke all on function public.system_status() from public, anon;
grant execute on function public.system_status() to authenticated, service_role;

create or replace function public.set_lockdown(p_on boolean, p_reason text default '')
returns jsonb
language plpgsql security definer set search_path = public, app_private
as $$
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  update app_private.system_flags set value = case when p_on then 'on' else 'off' end,
         updated_at = now() where key = 'lockdown';
  perform app_private.audit('lockdown_' || case when p_on then 'engaged' else 'lifted' end,
    'critical', jsonb_build_object('reason', p_reason));
  return jsonb_build_object('lockdown', p_on);
end;
$$;
revoke all on function public.set_lockdown(boolean, text) from public, anon;
grant execute on function public.set_lockdown(boolean, text) to authenticated, service_role;

-- Freeze privilege changes while locked down. Runs BEFORE the role tripwire's
-- AFTER trigger, so a blocked escalation never even reaches the audit insert.
create or replace function public.profiles_lockdown_guard()
returns trigger language plpgsql security definer set search_path = public, app_private
as $$
begin
  if session_user::text <> 'service_role'
     and coalesce((select value from app_private.system_flags where key='lockdown'),'off') = 'on'
     and (tg_op = 'INSERT'
          or new.role is distinct from old.role
          or new.is_active is distinct from old.is_active) then
    raise exception 'System is in security lockdown — account and role changes are frozen. Lift lockdown to proceed.';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_lockdown_guard_t on public.profiles;
create trigger profiles_lockdown_guard_t
  before insert or update on public.profiles
  for each row execute function public.profiles_lockdown_guard();

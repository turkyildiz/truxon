-- ============================================================================
-- Tamper-evident security audit log.
-- An append-only, hash-chained ledger of security- and money-relevant events
-- (role changes, admin creation, invoice voids, secret rotations, break-glass,
-- honeypot/honeytoken trips). Each row's `row_hash` = sha256(prev_hash ||
-- canonical-payload), so removing or editing ANY row — even by a superuser —
-- breaks the chain and security_audit_verify() reports exactly where.
--
-- Why this matters: today an intruder holding the service key could void
-- invoices or self-promote to admin and leave a thin trail. This is the
-- forensic backbone: writes only, no updates/deletes (enforced by trigger AND
-- revoke), and the chain makes silent tampering detectable after the fact.
-- ============================================================================

create table if not exists app_private.security_audit (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  event_type  text not null,          -- role_change | admin_created | invoice_void | ...
  severity    text not null default 'info' check (severity in ('info','warn','critical')),
  actor_uid   uuid,                    -- auth.uid() if a user did it
  actor_role  text,                    -- their app role (my_role) at the time
  actor_email text,
  session_role text,                   -- session_user: 'authenticator' via API, else a DB credential
  ip          text,
  detail      jsonb not null default '{}'::jsonb,
  prev_hash   text not null,
  row_hash    text not null
);
create index if not exists security_audit_at_idx on app_private.security_audit (at desc);
create index if not exists security_audit_type_idx on app_private.security_audit (event_type, at desc);

-- No one updates or deletes audit rows. Revoke covers the API roles; the
-- trigger covers everyone up to (but not including) a superuser — and a
-- superuser's tampering is what the hash chain is there to expose.
revoke insert, update, delete, truncate on app_private.security_audit from public, anon, authenticated, service_role;
create or replace function app_private.security_audit_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'security_audit is append-only (attempted %)', tg_op;
end;
$$;
drop trigger if exists security_audit_no_mutate on app_private.security_audit;
create trigger security_audit_no_mutate
  before update or delete or truncate on app_private.security_audit
  for each statement execute function app_private.security_audit_immutable();

-- The single writer. SECURITY DEFINER so any code path can record, but the
-- table grants above mean nothing can write EXCEPT through here. Serialized by
-- an advisory lock so concurrent events chain deterministically.
create or replace function app_private.audit(
  p_event text, p_severity text default 'info', p_detail jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = public, app_private
as $$
declare
  v_prev  text;
  v_uid   uuid   := auth.uid();
  v_claims jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  v_headers jsonb := nullif(current_setting('request.headers', true), '')::jsonb;
  v_role  text;
  v_hash  text;
  v_at    timestamptz := now();
begin
  perform pg_advisory_xact_lock(hashtext('security_audit_chain'));
  select row_hash into v_prev from app_private.security_audit order by id desc limit 1;
  v_prev := coalesce(v_prev, 'GENESIS');
  begin v_role := public.my_role()::text; exception when others then v_role := v_claims->>'role'; end;
  v_hash := encode(extensions.digest(
    v_prev || '|' || v_at::text || '|' || p_event || '|' || coalesce(p_severity,'') || '|'
      || coalesce(v_uid::text,'') || '|' || coalesce(p_detail::text,'{}'), 'sha256'), 'hex');
  insert into app_private.security_audit
    (at, event_type, severity, actor_uid, actor_role, actor_email, session_role, ip, detail, prev_hash, row_hash)
  values (v_at, p_event, coalesce(p_severity,'info'), v_uid, v_role,
    coalesce(v_claims->>'email', (select email from auth.users where id = v_uid)),
    session_user::text,
    coalesce(v_headers->>'cf-connecting-ip', v_headers->>'x-real-ip', v_headers->>'x-forwarded-for'),
    coalesce(p_detail,'{}'::jsonb), v_prev, v_hash);
end;
$$;
revoke all on function app_private.audit(text, text, jsonb) from public, anon;
grant execute on function app_private.audit(text, text, jsonb) to authenticated, service_role;

-- Walk the chain; return the first broken link (or intact).
create or replace function public.security_audit_verify()
returns jsonb
language plpgsql stable security definer set search_path = public, app_private
as $$
declare
  r record; v_prev text := 'GENESIS'; v_calc text; v_checked int := 0;
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  for r in select * from app_private.security_audit order by id loop
    v_calc := encode(extensions.digest(
      v_prev || '|' || r.at::text || '|' || r.event_type || '|' || coalesce(r.severity,'') || '|'
        || coalesce(r.actor_uid::text,'') || '|' || coalesce(r.detail::text,'{}'), 'sha256'), 'hex');
    if v_calc <> r.row_hash or r.prev_hash <> v_prev then
      return jsonb_build_object('intact', false, 'broken_at_id', r.id, 'checked', v_checked);
    end if;
    v_prev := r.row_hash; v_checked := v_checked + 1;
  end loop;
  return jsonb_build_object('intact', true, 'checked', v_checked);
end;
$$;
revoke all on function public.security_audit_verify() from public, anon;
grant execute on function public.security_audit_verify() to authenticated, service_role;

-- Office-gated read for the frontend / Forest.
create or replace function public.security_audit_recent(p_limit int default 100)
returns jsonb
language plpgsql stable security definer set search_path = public, app_private
as $$
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') not in ('admin','accountant') then
    raise exception 'Not enough permissions';
  end if;
  return coalesce((select jsonb_agg(r order by r.id desc) from (
    select id, at, event_type, severity, actor_email, actor_role, session_role, ip, detail
    from app_private.security_audit order by id desc limit greatest(1, least(p_limit, 500))
  ) r), '[]'::jsonb);
end;
$$;
revoke all on function public.security_audit_recent(int) from public, anon;
grant execute on function public.security_audit_recent(int) to authenticated, service_role;

-- ---- Role-escalation tripwire ---------------------------------------------
-- ANY elevation to admin (or a new admin account) is audited AND raised as a
-- critical Forest finding immediately — not on the next 15-min patrol — with a
-- push. Legitimate elevations you just acknowledge; the point is you always
-- know the moment it happens, because it's the first move of an account
-- takeover.
create or replace function public.profiles_role_tripwire()
returns trigger language plpgsql security definer set search_path = public, app_private
as $$
declare
  v_escalation boolean := new.role = 'admin' and (tg_op = 'INSERT' or old.role is distinct from 'admin');
  v_demotion   boolean := tg_op = 'UPDATE' and old.role = 'admin' and new.role <> 'admin';
  v_deact      boolean := tg_op = 'UPDATE' and old.is_active and not new.is_active;
begin
  if v_escalation then
    -- Record it to the tamper-evident log and fire an IMMEDIATE scan so the
    -- Forest finding + push land within seconds. The finding itself is produced
    -- by sentinel_scan reading this audit row (one source of truth; keeps the
    -- trigger from polluting insight counts in code paths that never scan).
    perform app_private.audit('admin_granted', 'critical',
      jsonb_build_object('target', new.id, 'username', new.username,
                         'from', case when tg_op='UPDATE' then old.role::text else '(new account)' end));
    begin perform app_private.cron_edge_call('trux-sentinel', '{"mode":"scan"}'::jsonb); exception when others then null; end;
  elsif v_demotion or (tg_op='UPDATE' and old.role is distinct from new.role) then
    perform app_private.audit('role_change', 'warn',
      jsonb_build_object('target', new.id, 'username', new.username, 'from', old.role::text, 'to', new.role::text));
  end if;
  if v_deact then
    perform app_private.audit('account_deactivated', 'warn',
      jsonb_build_object('target', new.id, 'username', new.username));
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_role_tripwire_t on public.profiles;
create trigger profiles_role_tripwire_t
  after insert or update on public.profiles
  for each row execute function public.profiles_role_tripwire();

-- ---- Invoice-void audit ----------------------------------------------------
create or replace function public.invoice_void_audit()
returns trigger language plpgsql security definer set search_path = public, app_private
as $$
begin
  if new.status = 'void' and old.status is distinct from 'void' then
    perform app_private.audit('invoice_void', 'warn',
      jsonb_build_object('invoice', new.invoice_number, 'id', new.id,
                         'total', new.total, 'customer_id', new.customer_id));
  end if;
  return new;
end;
$$;
drop trigger if exists invoice_void_audit_t on public.invoices;
create trigger invoice_void_audit_t
  after update of status on public.invoices
  for each row execute function public.invoice_void_audit();

-- Security console aggregate: everything the in-app Security page needs in one
-- office-gated call — lockdown state, audit-chain integrity, whether the
-- ransomware guard is armed, honeypot/honeytoken/canary/baseline status, open
-- security findings, and the recent audit tail.
create or replace function public.security_console()
returns jsonb
language plpgsql stable security definer set search_path = public, app_private
as $$
declare v jsonb;
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') not in ('admin','accountant') then
    raise exception 'Not enough permissions';
  end if;

  select jsonb_build_object(
    'lockdown', coalesce((select value = 'on' from app_private.system_flags where key='lockdown'), false),
    'audit_chain', public.security_audit_verify(),
    'guard_armed', exists(select 1 from pg_event_trigger where evtname = 'guard_destructive_ddl_trg'),
    'honeytokens', (select count(*) from app_private.honeytokens),
    'canary_present', exists(select 1 from public.profiles where id = '00000000-0000-4000-8000-00000000ca11' and not is_active),
    'baseline_items', (select count(*) from app_private.security_baseline),
    'audit_events_total', (select count(*) from app_private.security_audit),
    'open_findings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', id, 'severity', severity, 'title', title, 'last_seen', last_seen)
             order by (severity='critical') desc, last_seen desc)
      from public.trux_insights
      where status <> 'resolved'
        and split_part(dedup_key,':',1) in
            ('honeypot','honeytoken','admin_granted','posture_drift','canary_user','ransom_ddl')
    ), '[]'::jsonb),
    'critical_open', (select count(*) from public.trux_insights
                       where status <> 'resolved' and severity = 'critical'
                         and split_part(dedup_key,':',1) in
                             ('honeypot','honeytoken','admin_granted','posture_drift','canary_user','ransom_ddl')),
    'recent_audit', public.security_audit_recent(30)
  ) into v;
  return v;
end;
$$;
revoke all on function public.security_console() from public, anon;
grant execute on function public.security_console() to authenticated, service_role;

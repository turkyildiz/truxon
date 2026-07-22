-- Playbook march: the 2026-07-22 security build made a cluster of Technology
-- metrics honestly computable from real tables (audit log, honeypots, MFA
-- factors, security findings, POD OCR). One office-gated RPC surfaces them and
-- feeds the corresponding playbook rows.
create or replace function public.security_scorecard()
returns jsonb
language plpgsql security definer set search_path = public, app_private stable
as $$
declare
  v_office int;
  v_mfa int;
  v_chain jsonb;
  out jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select count(*) into v_office
    from public.profiles where is_active and role in ('admin','dispatcher','accountant','maintenance');
  select count(distinct f.user_id) into v_mfa
    from auth.mfa_factors f
    join public.profiles p on p.id = f.user_id and p.is_active
   where f.status = 'verified';
  v_chain := public.security_audit_verify();

  out := jsonb_build_object(
    -- #906 MFA Coverage %
    'mfa_coverage_pct', case when v_office > 0 then round(100.0 * v_mfa / v_office, 1) else null end,
    'mfa_enrolled_users', v_mfa,
    'office_users', v_office,
    -- #913 Cyber Incidents # (critical audited security events, trailing 30d)
    'cyber_incidents_30d', (select count(*) from app_private.security_audit
        where severity = 'critical' and at >= now() - interval '30 days'),
    'honeypot_hits_30d', (select count(*) from app_private.honeypot_hits
        where hit_at >= now() - interval '30 days'),
    -- #911 Vulnerabilities Open (critical) / #902 Critical Incident (P1):
    -- open critical security findings (honeypot/ransom/posture = compliance cat
    -- or the 'security' entity)
    'open_critical_security', (select count(*) from public.trux_insights
        where status = 'open' and severity = 'critical'
          and (category = 'compliance' or entity_type = 'security')),
    -- #916 Data Reconciliation Exceptions / Week (sentinel data-hygiene, 7d)
    'data_recon_exceptions_7d', (select count(*) from public.trux_insights
        where category = 'data' and last_seen >= now() - interval '7 days'),
    -- #929 POD OCR Success Rate %
    'pod_ocr_success_pct', (select case when count(*) > 0
        then round(100.0 * count(*) filter (where ocr_text is not null and ocr_text <> '') / count(*), 1)
        else null end
        from public.documents where doc_type in ('pod','bol','receipt','scale')),
    -- posture
    'audit_chain_intact', (v_chain->>'intact')::boolean,
    'ransomware_guard_armed', exists(select 1 from pg_event_trigger where evtname = 'guard_destructive_ddl_trg'),
    'as_of', now()
  );
  return out;
end;
$$;
revoke all on function public.security_scorecard() from public, anon;
grant execute on function public.security_scorecard() to authenticated, service_role;

-- Flip the now-computable rows live, each pointing at its source expression.
update public.playbook_metrics set status = 'live', source = 'security_scorecard().mfa_coverage_pct', updated_at = now() where number = 906;
update public.playbook_metrics set status = 'live', source = 'security_scorecard().cyber_incidents_30d', updated_at = now() where number = 913;
update public.playbook_metrics set status = 'live', source = 'security_scorecard().open_critical_security', updated_at = now() where number = 911;
update public.playbook_metrics set status = 'live', source = 'security_scorecard().open_critical_security (critical = P1)', updated_at = now() where number = 902;
update public.playbook_metrics set status = 'live', source = 'security_scorecard().data_recon_exceptions_7d', updated_at = now() where number = 916;
update public.playbook_metrics set status = 'live', source = 'security_scorecard().pod_ocr_success_pct', updated_at = now() where number = 929;

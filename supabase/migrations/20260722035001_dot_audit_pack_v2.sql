-- R9 #27: dot_audit_pack v2. Tonight's compliance build-out made the v1
-- not_tracked list stale — med-card, MVR reviews, drug/alcohol pool and
-- Clearinghouse queries ARE tracked now. Also counts the formal
-- service_type='dot_inspection' records the annual-inspection sentinel keys
-- off (v1's ilike patterns missed the enum value), and folds in DQF
-- completeness so this one call is the whole audit binder in numbers.
create or replace function public.dot_audit_pack()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') not in ('admin','accountant') then
    raise exception 'Not enough permissions';
  end if;
  return jsonb_build_object(
    'drivers_active', (select count(*) from drivers where status = 'active'),
    'cdl_on_file', (select count(*) from drivers where status = 'active'
                     and coalesce(license_number,'') <> ''),
    'cdl_expired', (select coalesce(jsonb_agg(jsonb_build_object('driver', full_name, 'expired', license_expiration)), '[]'::jsonb)
                     from drivers where status = 'active' and license_expiration < current_date),
    'cdl_expiring_60d', (select coalesce(jsonb_agg(jsonb_build_object('driver', full_name, 'expires', license_expiration)), '[]'::jsonb)
                          from drivers where status = 'active'
                            and license_expiration between current_date and current_date + 60),
    'medcard_on_file', (select count(*) from drivers where status = 'active' and medical_card_expiry is not null),
    'medcard_expired', (select coalesce(jsonb_agg(jsonb_build_object('driver', full_name, 'expired', medical_card_expiry)), '[]'::jsonb)
                         from drivers where status = 'active' and medical_card_expiry < current_date),
    'mvr_reviewed_12m', (select count(distinct e.driver_id) from driver_compliance_events e
                          join drivers d on d.id = e.driver_id and d.status = 'active'
                         where e.kind = 'mvr_review' and e.occurred_on > current_date - 365),
    'clearinghouse_12m', (select count(distinct e.driver_id) from driver_compliance_events e
                           join drivers d on d.id = e.driver_id and d.status = 'active'
                          where e.kind = 'clearinghouse_query' and e.occurred_on > current_date - 365),
    'drug_pool_enrolled', (select count(*) from drivers where status = 'active' and drug_pool_enrolled_on is not null),
    'dqf_complete', (public.driver_qual_files()->>'complete_count')::int,
    'trucks_active', (select count(*) from trucks where status <> 'retired'),
    'plates_expired', (select coalesce(jsonb_agg(jsonb_build_object('unit', unit_number, 'expired', plate_expiry)), '[]'::jsonb)
                        from trucks where status <> 'retired' and plate_expiry < current_date),
    'annual_inspection_current', (
      select count(distinct t.id) from trucks t
       where t.status <> 'retired' and exists (
         select 1 from maintenance_records m
          where m.truck_id = t.id and m.status = 'completed'
            and (m.service_type::text = 'dot_inspection'
                 or m.service_type::text ilike '%annual%' or m.service_type::text ilike '%dot inspect%'
                 or m.description ilike '%annual inspection%' or m.description ilike '%dot inspection%')
            and m.date_completed > current_date - 365)),
    'eld_reporting_7d', (select count(distinct truck_id) from eld_daily_miles where day > current_date - 7),
    'dvir_drivers_30d', (select count(distinct driver_id) from dvir where created_at > now() - interval '30 days'),
    'safety_events_365d', (select count(*) from safety_events where created_at > now() - interval '365 days'),
    'not_tracked', jsonb_build_array(
      'previous-employer safety performance history (391.23 investigations)',
      'full Clearinghouse query RESULTS (only the query date is logged)'),
    'as_of', now());
end;
$$;
revoke execute on function public.dot_audit_pack() from public, anon;
grant execute on function public.dot_audit_pack() to authenticated, service_role;

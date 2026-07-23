-- Hotfix on 025001, caught on first live read: maintenance_records.status is
-- the maintenance_status ENUM — coalesce(status,'') coerced '' to the enum and
-- blew up (and 'draft' isn't a value anyway; completed work is what counts).
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
    'trucks_active', (select count(*) from trucks where status <> 'retired'),
    'plates_expired', (select coalesce(jsonb_agg(jsonb_build_object('unit', unit_number, 'expired', plate_expiry)), '[]'::jsonb)
                        from trucks where status <> 'retired' and plate_expiry < current_date),
    'annual_inspection_current', (
      select count(distinct t.id) from trucks t
       where t.status <> 'retired' and exists (
         select 1 from maintenance_records m
          where m.truck_id = t.id and m.status = 'completed'
            and (m.service_type ilike '%annual%' or m.service_type ilike '%dot inspect%'
                 or m.description ilike '%annual inspection%' or m.description ilike '%dot inspection%')
            and m.date_completed > current_date - 365)),
    'eld_reporting_7d', (select count(distinct truck_id) from eld_daily_miles where day > current_date - 7),
    'dvir_drivers_30d', (select count(distinct driver_id) from dvir where created_at > now() - interval '30 days'),
    'safety_events_365d', (select count(*) from safety_events where created_at > now() - interval '365 days'),
    'not_tracked', jsonb_build_array(
      'medical card (DOT physical) expiry per driver',
      'drug & alcohol testing program / clearinghouse queries',
      'MVR annual review records',
      'previous-employer safety performance history'),
    'as_of', now());
end;
$$;
revoke execute on function public.dot_audit_pack() from public, anon;
grant execute on function public.dot_audit_pack() to authenticated, service_role;

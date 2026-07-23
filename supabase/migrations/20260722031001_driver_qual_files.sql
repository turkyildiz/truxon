-- R9 #22/23: Driver Qualification File completeness — the one screen a DOT
-- auditor walks in with. Per active driver: CDL number/expiry, medical card,
-- and whether the paper is actually ON FILE (License / Medical Card docs).
-- Vision backfill (R9 #16-17) stays blocked until these docs exist; this page
-- is what shows the office exactly what to photograph.
create or replace function public.driver_qual_files()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'drivers', coalesce(jsonb_agg(row order by (row->>'complete')::boolean, row->>'driver'), '[]'::jsonb),
    'complete_count', count(*) filter (where (row->>'complete')::boolean),
    'total', count(*))
  from (
    select jsonb_build_object(
      'driver_id', d.id,
      'driver', d.full_name,
      'cdl_number_on_record', coalesce(d.license_number,'') <> '',
      'cdl_expiry', d.license_expiration,
      'cdl_ok', coalesce(d.license_number,'') <> '' and d.license_expiration > current_date,
      'medcard_expiry', d.medical_card_expiry,
      'medcard_ok', d.medical_card_expiry is not null and d.medical_card_expiry > current_date,
      'license_doc_on_file', exists (select 1 from documents doc
        where doc.entity_type='driver' and doc.entity_id=d.id and doc.doc_type='License'),
      'medcard_doc_on_file', exists (select 1 from documents doc
        where doc.entity_type='driver' and doc.entity_id=d.id and doc.doc_type='Medical Card'),
      'complete',
        coalesce(d.license_number,'') <> '' and d.license_expiration > current_date
        and d.medical_card_expiry is not null and d.medical_card_expiry > current_date
        and exists (select 1 from documents doc
          where doc.entity_type='driver' and doc.entity_id=d.id and doc.doc_type='License')
        and exists (select 1 from documents doc
          where doc.entity_type='driver' and doc.entity_id=d.id and doc.doc_type='Medical Card')
    ) as row
    from drivers d
    where d.status = 'active'
      and (auth.role() = 'service_role' or public.my_role() in ('admin','accountant'))
  ) x;
$$;
revoke all on function public.driver_qual_files() from public, anon;
grant execute on function public.driver_qual_files() to authenticated, service_role;

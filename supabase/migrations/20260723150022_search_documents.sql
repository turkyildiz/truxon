-- R9 #153: the omnibox finds paperwork too. Documents match on filename or
-- doc type and carry their owning entity so the UI can land on the right
-- page (deep content search stays on /docsearch — this is the quick grab).
create or replace function public.global_search(q text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.my_role() is null or public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return jsonb_build_object(
    'loads', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'label', l.load_number || ' — ' || c.company_name))
                from (select * from public.loads
                       where load_number ilike '%' || q || '%'
                          or reference_number ilike '%' || q || '%'
                          or pickup_address ilike '%' || q || '%'
                          or delivery_address ilike '%' || q || '%' limit 10) l
                join public.customers c on c.id = l.customer_id), '[]'::jsonb),
    'customers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', company_name))
                    from (select id, company_name from public.customers where company_name ilike '%' || q || '%' limit 10) c), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', full_name))
                  from (select id, full_name from public.drivers where full_name ilike '%' || q || '%' limit 10) d), '[]'::jsonb),
    'trucks', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', unit_number))
                 from (select id, unit_number from public.trucks where unit_number ilike '%' || q || '%' limit 10) t), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', d.id, 'entity_type', d.entity_type, 'entity_id', d.entity_id,
                    'label', d.filename || case when d.doc_type <> '' then ' — ' || d.doc_type else '' end
                             || ' (' || d.entity_type
                             || case when d.load_number is not null then ' ' || d.load_number else '' end || ')'))
                  from (select doc.id, doc.entity_type, doc.entity_id, doc.filename, doc.doc_type,
                               l.load_number
                          from public.documents doc
                          left join public.loads l on doc.entity_type = 'load' and l.id = doc.entity_id
                         where doc.filename ilike '%' || q || '%'
                            or doc.doc_type ilike '%' || q || '%'
                         order by doc.uploaded_at desc limit 10) d), '[]'::jsonb)
  );
end;
$$;

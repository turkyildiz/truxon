-- R9 #112: storage usage report. documents.size_bytes has been banked since
-- day one — roll it up so runaway upload growth is visible before the bucket
-- bill is (pairs with sentinel #85's growth-anomaly watch).
create or replace function public.storage_usage_report()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when coalesce(auth.role(), '') = 'service_role'
              or public.my_role() in ('admin','dispatcher','accountant')
  then jsonb_build_object(
    'total_bytes', (select coalesce(sum(size_bytes),0) from documents),
    'docs', (select count(*) from documents),
    'by_entity', (select coalesce(jsonb_object_agg(entity_type, s), '{}'::jsonb) from
      (select entity_type, jsonb_build_object('docs', count(*), 'bytes', coalesce(sum(size_bytes),0)) s
       from documents group by entity_type) x),
    'by_type', (select coalesce(jsonb_object_agg(coalesce(nullif(doc_type,''),'(untyped)'), s), '{}'::jsonb) from
      (select doc_type, jsonb_build_object('docs', count(*), 'bytes', coalesce(sum(size_bytes),0)) s
       from documents group by doc_type) x),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object(
        'month', to_char(m, 'YYYY-MM'), 'docs', n, 'bytes', b) order by m), '[]'::jsonb) from
      (select date_trunc('month', uploaded_at) m, count(*) n, coalesce(sum(size_bytes),0) b
       from documents where uploaded_at > now() - interval '12 months'
       group by 1) x),
    'largest', (select coalesce(jsonb_agg(jsonb_build_object(
        'document_id', id, 'filename', filename, 'doc_type', doc_type,
        'entity', entity_type||'/'||entity_id, 'bytes', size_bytes) order by size_bytes desc), '[]'::jsonb) from
      (select * from documents where size_bytes is not null
       order by size_bytes desc limit 15) x),
    'as_of', now())
  end;
$$;
revoke all on function public.storage_usage_report() from public, anon;
grant execute on function public.storage_usage_report() to authenticated, service_role;

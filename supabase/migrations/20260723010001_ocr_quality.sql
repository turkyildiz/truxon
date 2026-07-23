-- R9 #103: OCR quality — which PDFs produced garbage text. A sizeable indexed
-- PDF whose extraction yielded almost nothing is a bad scan (skewed photo,
-- fax-of-a-fax): the re-scan queue names them so the office can re-shoot the
-- ones that matter (PODs first — brokers reject unreadable ones).
create or replace function public.ocr_quality_report(p_limit int default 25)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  with txt as (
    select d.id, d.filename, d.doc_type, d.entity_type, d.entity_id, d.size_bytes,
           coalesce(sum(length(e.content)), 0) as chars
      from documents d
      left join document_embeddings e on e.document_id = d.id
     where d.indexed_at is not null
       and (d.content_type ilike '%pdf%' or d.filename ilike '%.pdf')
     group by d.id
  )
  select jsonb_build_object(
    'indexed_pdfs', (select count(*) from txt),
    'garbage', (select count(*) from txt where size_bytes > 50000 and chars < 200),
    'garbage_pct', (select round(100.0 * count(*) filter (where size_bytes > 50000 and chars < 200)
                      / nullif(count(*), 0), 1) from txt),
    'rescan_queue', coalesce((select jsonb_agg(jsonb_build_object(
        'document_id', t.id, 'filename', t.filename, 'doc_type', t.doc_type,
        'entity', t.entity_type || ' #' || t.entity_id,
        'kb', round(t.size_bytes / 1024.0, 0), 'chars', t.chars)
        order by case when t.doc_type = 'POD' then 0 else 1 end, t.size_bytes desc)
      from (select * from txt where size_bytes > 50000 and chars < 200
             limit least(greatest(p_limit, 1), 100)) t), '[]'::jsonb),
    'note', 'garbage = >50KB PDF that extracted under 200 characters; PODs sort first',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.ocr_quality_report(int) from public, anon;
grant execute on function public.ocr_quality_report(int) to authenticated, service_role;

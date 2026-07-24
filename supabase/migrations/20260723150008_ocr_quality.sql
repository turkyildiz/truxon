-- R9 #103: OCR quality score + re-scan queue. A doc whose indexed text is
-- thin or mostly non-alphanumeric came off a garbage scan — search can't find
-- it and the classifier can't read it. Score is a plain heuristic (no LLM):
--   chars indexed + share of recognizable word characters.
-- The worklist is docs worth re-photographing, worst first.
create or replace function public.doc_ocr_quality_report(p_limit int default 50)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when coalesce(auth.role(), '') = 'service_role'
              or public.my_role() in ('admin','dispatcher','accountant')
  then (
    with doc_text as (
      select d.id, d.filename, d.doc_type, d.entity_type, d.entity_id,
             coalesce(string_agg(e.content, ' '), '') as txt
      from documents d
      left join document_embeddings e on e.document_id = d.id
      group by d.id, d.filename, d.doc_type, d.entity_type, d.entity_id
    ),
    scored as (
      select *, length(txt) as chars,
             case when length(txt) = 0 then 0
                  else round(100.0 * (length(txt) - length(regexp_replace(txt, '[a-zA-Z0-9 ]', '', 'g')))
                             / length(txt)) end as word_pct,
             case
               when length(txt) = 0 then 'no_text'          -- image-only: vision queue
               when length(txt) < 200 then 'thin'
               when (length(txt) - length(regexp_replace(txt, '[a-zA-Z0-9 ]', '', 'g')))::numeric
                    / length(txt) < 0.70 then 'garbled'
               else 'ok' end as verdict
      from doc_text
    )
    select jsonb_build_object(
      'docs', (select count(*) from scored),
      'ok', (select count(*) from scored where verdict = 'ok'),
      'no_text', (select count(*) from scored where verdict = 'no_text'),
      'thin', (select count(*) from scored where verdict = 'thin'),
      'garbled', (select count(*) from scored where verdict = 'garbled'),
      'rescan_queue', coalesce((
        select jsonb_agg(jsonb_build_object(
          'document_id', id, 'filename', filename, 'doc_type', doc_type,
          'entity', entity_type||'/'||entity_id, 'verdict', verdict,
          'chars', chars, 'word_pct', word_pct)
          order by (verdict = 'garbled') desc, chars asc)
        from (select * from scored where verdict in ('thin','garbled')
               order by (verdict = 'garbled') desc, chars asc limit p_limit) q), '[]'::jsonb),
      'as_of', now())
  ) end;
$$;
revoke all on function public.doc_ocr_quality_report(int) from public, anon;
grant execute on function public.doc_ocr_quality_report(int) to authenticated, service_role;

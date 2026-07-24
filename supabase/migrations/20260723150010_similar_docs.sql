-- R9 #108: "more like this" for documents. Uses the source doc's FIRST chunk
-- as its representative (this pgvector build ships no avg(vector) aggregate;
-- chunk 0 is the doc's opening — the most type-identifying text) and ranks
-- other docs by their closest chunk's cosine similarity. Same-embedding-space
-- only; image-only docs have no vector and can't match.
-- search_path includes extensions: the <=> operator lives there.
create or replace function public.similar_documents(p_document_id bigint, p_limit int default 8)
returns jsonb
language sql stable security definer set search_path = public, extensions
as $$
  select case when coalesce(auth.role(), '') = 'service_role'
              or public.my_role() in ('admin','dispatcher','accountant')
  then (
    with src as (
      select embedding as v
      from document_embeddings where document_id = p_document_id
      order by chunk_index asc limit 1
    ),
    ranked as (
      select e.document_id, min(e.embedding <=> (select v from src)) as dist
      from document_embeddings e, src
      where src.v is not null and e.document_id <> p_document_id and e.document_id is not null
      group by e.document_id
      order by dist asc
      limit greatest(least(p_limit, 25), 1)
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'document_id', r.document_id,
      'filename', d.filename,
      'doc_type', d.doc_type,
      'entity', d.entity_type||'/'||d.entity_id,
      'similarity', round((1 - r.dist)::numeric, 3))
      order by r.dist asc), '[]'::jsonb)
    from ranked r join documents d on d.id = r.document_id
  ) end;
$$;
revoke all on function public.similar_documents(bigint, int) from public, anon;
grant execute on function public.similar_documents(bigint, int) to authenticated, service_role;

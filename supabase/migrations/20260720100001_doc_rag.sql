-- Document semantic search (RAG). The NAS extracts text from every document
-- (poppler for text-layer, the vision pipeline for scanned) and embeds it with a
-- local model (nomic-embed-text, 768-dim) — free + private. Vectors land here in
-- pgvector; Trux searches them by meaning, not keywords.
--
--   document_embeddings         one row per text chunk + its 768-d vector
--   documents.indexed_at        when a doc was last embedded
--   upsert_doc_embeddings()     service-side: replace a doc's chunks (NAS worker)
--   match_document_embeddings() admin: cosine-similarity search

create extension if not exists vector with schema extensions;

alter table public.documents add column if not exists indexed_at timestamptz;

create table if not exists public.document_embeddings (
  id bigint generated always as identity primary key,
  document_id bigint not null references public.documents (id) on delete cascade,
  entity_type text not null,
  entity_id bigint not null,
  chunk_index int not null default 0,
  content text not null,
  embedding extensions.vector(768) not null,
  created_at timestamptz not null default now()
);
create index if not exists document_embeddings_doc_idx on public.document_embeddings (document_id);
create index if not exists document_embeddings_entity_idx on public.document_embeddings (entity_type, entity_id);
-- approximate-nearest-neighbour index for fast cosine search
create index if not exists document_embeddings_vec_idx on public.document_embeddings
  using hnsw (embedding extensions.vector_cosine_ops);
alter table public.document_embeddings enable row level security;
-- no policies: service writes, admin reads via the RPC below

-- ── service upsert (NAS indexer) ────────────────────────────────────────────
-- Replace-by-document: each call re-writes one document's chunks.
create or replace function public.upsert_doc_embeddings(
  p_document_id bigint,
  p_entity_type text,
  p_entity_id bigint,
  p_chunks jsonb
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_n int;
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  delete from document_embeddings where document_id = p_document_id;
  insert into document_embeddings (document_id, entity_type, entity_id, chunk_index, content, embedding)
  select p_document_id, p_entity_type, p_entity_id,
         (row_number() over ())::int - 1,
         c->>'content',
         ((c->'embedding')::text)::extensions.vector
  from jsonb_array_elements(coalesce(p_chunks, '[]'::jsonb)) c
  where coalesce(c->>'content', '') <> '';
  get diagnostics v_n = row_count;
  update documents set indexed_at = now() where id = p_document_id;
  return v_n;
end;
$$;
revoke all on function public.upsert_doc_embeddings(bigint, text, bigint, jsonb) from public, anon, authenticated;

-- ── admin similarity search ─────────────────────────────────────────────────
create or replace function public.match_document_embeddings(
  p_embedding text,
  p_count int default 12,
  p_entity_type text default null
)
returns table (
  document_id bigint,
  entity_type text,
  entity_id bigint,
  filename text,
  doc_type text,
  content text,
  similarity real
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  -- service role (edge fn, auth.uid() null) is allowed — the edge gates the HTTP
  -- caller; a direct authenticated user must be admin/dispatcher/accountant.
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return query
  select de.document_id, de.entity_type, de.entity_id, d.filename, d.doc_type,
         de.content,
         (1 - (de.embedding <=> (p_embedding)::extensions.vector))::real as similarity
  from document_embeddings de
  join documents d on d.id = de.document_id
  where p_entity_type is null or de.entity_type = p_entity_type
  order by de.embedding <=> (p_embedding)::extensions.vector
  limit least(greatest(p_count, 1), 50);
end;
$$;
revoke all on function public.match_document_embeddings(text, int, text) from public, anon;

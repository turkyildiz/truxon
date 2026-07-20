-- Team Drive joins document search (owner request 2026-07-20): the shared
-- Dropbox-like drive holds contracts, agreements, and insurance paperwork that
-- isn't attached to any load/customer — index those PDFs too.
--
--   drive_files.indexed_at        when a team file was last embedded
--   document_embeddings           +drive_file_id (a chunk belongs to a document
--                                 OR a team-drive file, never both)
--   upsert_drive_embeddings()     service-side: replace one file's chunks
--   match_document_embeddings()   now returns drive hits alongside doc hits
--
-- Personal Drive stays out on purpose — it's private per employee.

alter table public.drive_files add column if not exists indexed_at timestamptz;

alter table public.document_embeddings alter column document_id drop not null;
alter table public.document_embeddings
  add column if not exists drive_file_id bigint references public.drive_files (id) on delete cascade;
alter table public.document_embeddings drop constraint if exists document_embeddings_one_source;
alter table public.document_embeddings
  add constraint document_embeddings_one_source
  check ((document_id is null) <> (drive_file_id is null));
create index if not exists document_embeddings_drive_file_idx
  on public.document_embeddings (drive_file_id);

-- ── service upsert (NAS indexer), team-drive flavour ────────────────────────
create or replace function public.upsert_drive_embeddings(
  p_drive_file_id bigint,
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
  delete from document_embeddings where drive_file_id = p_drive_file_id;
  insert into document_embeddings (drive_file_id, entity_type, entity_id, chunk_index, content, embedding)
  select p_drive_file_id, 'team_drive', p_drive_file_id,
         (row_number() over ())::int - 1,
         c->>'content',
         ((c->'embedding')::text)::extensions.vector
  from jsonb_array_elements(coalesce(p_chunks, '[]'::jsonb)) c
  where coalesce(c->>'content', '') <> '';
  get diagnostics v_n = row_count;
  update drive_files set indexed_at = now() where id = p_drive_file_id;
  return v_n;
end;
$$;
revoke all on function public.upsert_drive_embeddings(bigint, jsonb) from public, anon, authenticated;

-- ── similarity search now unions doc + drive sources ────────────────────────
-- Return shape changes (drive_file_id added, document_id nullable), so the old
-- function is dropped rather than replaced.
drop function if exists public.match_document_embeddings(text, int, text);
create function public.match_document_embeddings(
  p_embedding text,
  p_count int default 12,
  p_entity_type text default null
)
returns table (
  document_id bigint,
  drive_file_id bigint,
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
  select de.document_id, de.drive_file_id, de.entity_type, de.entity_id,
         coalesce(d.filename, df.filename) as filename,
         coalesce(d.doc_type, 'team drive') as doc_type,
         de.content,
         (1 - (de.embedding <=> (p_embedding)::extensions.vector))::real as similarity
  from document_embeddings de
  left join documents d on d.id = de.document_id
  left join drive_files df on df.id = de.drive_file_id
  where p_entity_type is null or de.entity_type = p_entity_type
  order by de.embedding <=> (p_embedding)::extensions.vector
  limit least(greatest(p_count, 1), 50);
end;
$$;
revoke all on function public.match_document_embeddings(text, int, text) from public, anon;

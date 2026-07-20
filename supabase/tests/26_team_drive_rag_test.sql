-- Team Drive embeddings: service upsert (replace-by-file, indexed_at), the
-- one-source check constraint, and cascade on file delete.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

-- an uploader for the drive file
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000e26'::uuid, 'drive@test.local');
insert into public.drive_files (drive, owner_id, filename, storage_path, content_type)
values ('team', '00000000-0000-4000-8000-000000000e26', 'insurance-policy.pdf',
        '00000000-0000-4000-8000-000000000e26/x_insurance-policy.pdf', 'application/pdf');

-- a 768-dim zero vector as a JSON array (matches nomic-embed-text dims)
create temporary table _v as select jsonb_agg(0) as emb from generate_series(1, 768);

-- ── service context ──
select set_config('request.jwt.claims', '', true);

select is(
  public.upsert_drive_embeddings(
    (select id from public.drive_files where filename = 'insurance-policy.pdf'),
    jsonb_build_array(
      jsonb_build_object('content', 'liability limits', 'embedding', (select emb from _v)),
      jsonb_build_object('content', 'cargo coverage', 'embedding', (select emb from _v))
    )
  ), 2, 'upsert stores two drive chunks');

select isnt((select indexed_at from public.drive_files where filename = 'insurance-policy.pdf'),
  null, 'drive_files.indexed_at stamped');
select is((select entity_type from public.document_embeddings where drive_file_id is not null limit 1),
  'team_drive', 'drive chunks carry team_drive entity_type');

-- re-upsert replaces (no dupes)
select is(
  public.upsert_drive_embeddings(
    (select id from public.drive_files where filename = 'insurance-policy.pdf'),
    jsonb_build_array(jsonb_build_object('content', 'only chunk', 'embedding', (select emb from _v)))
  ), 1, 're-upsert replaces drive chunks');

-- one-source constraint: a chunk can't claim both a document and a drive file
select throws_like($$
  insert into public.document_embeddings (document_id, drive_file_id, entity_type, entity_id, content, embedding)
  select null, null, 'x', 0, 'orphan',
         (('[' || array_to_string(array(select '0' from generate_series(1,768)), ',') || ']'))::extensions.vector
$$, '%document_embeddings_one_source%', 'chunk must have exactly one source');

-- deleting the drive file cascades its chunks away
delete from public.drive_files where filename = 'insurance-policy.pdf';
select is((select count(*)::int from public.document_embeddings where drive_file_id is not null),
  0, 'drive file delete cascades to chunks');

select * from finish();
rollback;

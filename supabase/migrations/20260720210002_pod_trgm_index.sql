-- Speed up the missing-POD archive cross-reference: it matches a load's
-- container/reference number against 8k+ Team Drive filenames with ILIKE
-- '%ref%' (leading wildcard → no btree help). A trigram GIN index makes those
-- substring searches fast.

create extension if not exists pg_trgm with schema extensions;

create index if not exists drive_files_filename_trgm
  on public.drive_files using gin (filename extensions.gin_trgm_ops);

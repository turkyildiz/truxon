-- documents had no UPDATE policy, so metadata edits (rename, reclassify)
-- silently affected 0 rows under RLS. Allow office roles to update document
-- metadata (same visibility surface as documents_select), and maintenance to
-- update equipment/repair docs. Storage objects are unchanged; this is the
-- metadata row only.

create policy documents_update on public.documents
  for update to authenticated
  using (
    public.my_role() in ('admin', 'dispatcher', 'accountant')
    or (public.my_role() = 'maintenance' and entity_type in ('truck', 'trailer', 'maintenance'))
  )
  with check (
    public.my_role() in ('admin', 'dispatcher', 'accountant')
    or (public.my_role() = 'maintenance' and entity_type in ('truck', 'trailer', 'maintenance'))
  );

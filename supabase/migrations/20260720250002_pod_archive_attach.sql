-- One-click "attach from archive" for a missing POD, plus a correctness fix.
--
-- FIX: loads_missing_pod matched doc_type in lowercase ('pod','bol',…), but the
-- web Documents panel stores the type verbatim ('POD','BOL'). So a POD attached
-- from the browser was invisible to the detector and the load kept showing as
-- missing. Match case-insensitively. (Driver-app and Forest uploads already
-- lowercase, so those were fine.)
create or replace function public.loads_missing_pod(p_days int default 45)
returns table (
  load_id bigint,
  load_number text,
  customer text,
  status text,
  delivered_at timestamptz,
  reference_number text,
  pickup_number text,
  delivery_number text
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return query
  select l.id, l.load_number,
         (select c.company_name from customers c where c.id = l.customer_id),
         l.status::text, l.delivery_time, l.reference_number, l.pickup_number, l.delivery_number
  from loads l
  where l.status in ('delivered', 'completed', 'billed')
    and coalesce(l.delivery_time, l.updated_at) > now() - make_interval(days => p_days)
    and not exists (
      select 1 from documents d
      where d.entity_type = 'load' and d.entity_id = l.id
        and lower(d.doc_type) in ('pod', 'bol', 'receipt', 'scale')
    )
  order by l.delivery_time desc nulls last;
end;
$$;
revoke all on function public.loads_missing_pod(int) from public, anon;

-- The specific PODs-archive file that matches a load (id + path so the app can
-- copy it into the load's Documents). Same trigram match as pod_archive_candidate,
-- but returns enough to attach it. Admin/dispatcher/accountant only.
create or replace function public.pod_archive_candidate_file(p_load_id bigint)
returns table (drive_file_id bigint, filename text, storage_path text, content_type text)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select c.id, c.filename, c.storage_path, c.content_type
  from public.loads l
  cross join lateral (
    select df.id, df.filename, df.storage_path, df.content_type
    from public.drive_files df
    where df.drive = 'team' and df.is_folder = false and df.filename is not null
      and (
        (length(coalesce(l.reference_number, '')) >= 5 and df.filename ilike '%' || l.reference_number || '%') or
        (length(coalesce(l.pickup_number, '')) >= 5    and df.filename ilike '%' || l.pickup_number || '%') or
        (length(coalesce(l.delivery_number, '')) >= 5  and df.filename ilike '%' || l.delivery_number || '%')
      )
    limit 1
  ) c
  where l.id = p_load_id
    and (auth.uid() is null or public.my_role() in ('admin', 'dispatcher', 'accountant'));
$$;
revoke all on function public.pod_archive_candidate_file(bigint) from public, anon;
grant execute on function public.pod_archive_candidate_file(bigint) to authenticated;

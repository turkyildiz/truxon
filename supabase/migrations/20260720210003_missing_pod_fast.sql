-- Missing-POD, made fast + actionable. The archive cross-reference over 8k Team
-- Drive files was run for EVERY missing load (≈900 historical billed loads with
-- no attached POD) → statement timeout. Split it:
--   loads_missing_pod()      — fast core list (no archive scan)
--   pod_archive_candidate()  — one indexed trigram lookup for a single load,
--                              called on demand for the rows actually shown
-- Also default to a short window: a missing POD matters most on loads that
-- aren't billed yet (you can't invoice without it) or were billed very recently.

-- 210001 returned a different column set — drop before recreating (return-type change)
drop function if exists public.loads_missing_pod(int);
drop function if exists public.loads_missing_pod_summary(int);

create function public.loads_missing_pod(p_days int default 45)
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
        and d.doc_type in ('pod', 'bol', 'receipt', 'scale')
    )
  order by l.delivery_time desc nulls last;
end;
$$;
revoke all on function public.loads_missing_pod(int) from public, anon;

-- One indexed trigram lookup: does the PODs/ archive hold a file for this load?
create or replace function public.pod_archive_candidate(p_ref text, p_pickup text default '', p_delivery text default '')
returns text
language sql
security definer
set search_path = public, extensions
stable
as $$
  select df.filename from drive_files df
  where df.drive = 'team' and df.is_folder = false and df.filename is not null
    and (
      (length(coalesce(p_ref, '')) >= 5      and df.filename ilike '%' || p_ref || '%') or
      (length(coalesce(p_pickup, '')) >= 5   and df.filename ilike '%' || p_pickup || '%') or
      (length(coalesce(p_delivery, '')) >= 5 and df.filename ilike '%' || p_delivery || '%')
    )
  limit 1;
$$;
revoke all on function public.pod_archive_candidate(text, text, text) from public, anon;

create function public.loads_missing_pod_summary(p_days int default 45)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select jsonb_build_object('missing', count(*), 'days', p_days)
  from public.loads_missing_pod(p_days);
$$;
revoke all on function public.loads_missing_pod_summary(int) from public, anon;

-- Missing-POD detection (#2). A delivered/billed load with no proof-of-delivery
-- on file is money waiting to stall — brokers won't pay without the POD. This
-- finds them AND cross-references the imported PODs/ archive (Team Drive) by the
-- load's reference/container numbers, so a POD that exists but isn't attached
-- surfaces as a one-step fix instead of a re-request.

-- delivery-evidence doc types (mirror driver_pod_upload's allow-list)
create or replace function public.loads_missing_pod(p_days int default 120)
returns table (
  load_id bigint,
  load_number text,
  customer text,
  status text,
  delivered_at timestamptz,
  reference text,
  archive_file text
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
  with delivered as (
    select l.id, l.load_number, l.status::text as status, l.delivery_time, l.updated_at,
           l.reference_number, l.pickup_number, l.delivery_number,
           (select c.company_name from customers c where c.id = l.customer_id) as customer
    from loads l
    where l.status in ('delivered', 'completed', 'billed')
      and coalesce(l.delivery_time, l.updated_at) > now() - make_interval(days => p_days)
      and not exists (
        select 1 from documents d
        where d.entity_type = 'load' and d.entity_id = l.id
          and d.doc_type in ('pod', 'bol', 'receipt', 'scale')
      )
  )
  select d.id, d.load_number, d.customer, d.status, d.delivery_time,
         nullif(concat_ws(' / ', nullif(d.reference_number, ''), nullif(d.pickup_number, ''), nullif(d.delivery_number, '')), ''),
         (select df.filename from drive_files df
            where df.drive = 'team' and df.is_folder = false and df.filename is not null
              and (
                (length(d.reference_number) >= 5 and df.filename ilike '%' || d.reference_number || '%') or
                (length(d.pickup_number)   >= 5 and df.filename ilike '%' || d.pickup_number   || '%') or
                (length(d.delivery_number) >= 5 and df.filename ilike '%' || d.delivery_number || '%')
              )
            limit 1)
  from delivered d
  order by d.delivery_time desc nulls last;
end;
$$;
revoke all on function public.loads_missing_pod(int) from public, anon;

-- headline counts for a dashboard/Forest ("how many loads are missing PODs?")
create or replace function public.loads_missing_pod_summary(p_days int default 120)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select jsonb_build_object(
    'missing', count(*),
    'in_archive', count(*) filter (where archive_file is not null),
    'need_request', count(*) filter (where archive_file is null)
  )
  from public.loads_missing_pod(p_days);
$$;
revoke all on function public.loads_missing_pod_summary(int) from public, anon;

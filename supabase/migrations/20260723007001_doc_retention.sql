-- R9 #110: document retention report — what's actually on file per entity
-- class, as coverage percentages with the gap counts an office can work:
-- loads (rate con / POD / BOL), drivers (license / med card), trucks
-- (registration / insurance). One call for "are our files complete".
create or replace function public.doc_retention_report(p_days int default 90)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  with l as (
    select l.id,
           exists (select 1 from documents d where d.entity_type='load' and d.entity_id=l.id and d.doc_type='Rate Confirmation') as rc,
           exists (select 1 from documents d where d.entity_type='load' and d.entity_id=l.id and d.doc_type='POD') as pod,
           exists (select 1 from documents d where d.entity_type='load' and d.entity_id=l.id and d.doc_type='BOL') as bol
      from loads l
     where l.status in ('completed','billed')
       and l.delivery_time > now() - make_interval(days => p_days)
  ), dr as (
    select d.id,
           exists (select 1 from documents x where x.entity_type='driver' and x.entity_id=d.id and x.doc_type='License') as lic,
           exists (select 1 from documents x where x.entity_type='driver' and x.entity_id=d.id and x.doc_type='Medical Card') as med
      from drivers d where d.status = 'active'
  ), tk as (
    select t.id,
           exists (select 1 from documents x where x.entity_type='truck' and x.entity_id=t.id and x.doc_type='Registration') as reg,
           exists (select 1 from documents x where x.entity_type='truck' and x.entity_id=t.id and x.doc_type='Insurance') as ins
      from trucks t where t.status <> 'retired'
  )
  select jsonb_build_object(
    'window_days', p_days,
    'loads', (select jsonb_build_object(
        'n', count(*),
        'rate_con_pct', round(100.0 * count(*) filter (where rc) / nullif(count(*),0), 0),
        'pod_pct', round(100.0 * count(*) filter (where pod) / nullif(count(*),0), 0),
        'bol_pct', round(100.0 * count(*) filter (where bol) / nullif(count(*),0), 0),
        'missing_pod', count(*) filter (where not pod)) from l),
    'drivers', (select jsonb_build_object(
        'n', count(*),
        'license_doc_pct', round(100.0 * count(*) filter (where lic) / nullif(count(*),0), 0),
        'medcard_doc_pct', round(100.0 * count(*) filter (where med) / nullif(count(*),0), 0)) from dr),
    'trucks', (select jsonb_build_object(
        'n', count(*),
        'registration_doc_pct', round(100.0 * count(*) filter (where reg) / nullif(count(*),0), 0),
        'insurance_doc_pct', round(100.0 * count(*) filter (where ins) / nullif(count(*),0), 0)) from tk),
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.doc_retention_report(int) from public, anon;
grant execute on function public.doc_retention_report(int) to authenticated, service_role;

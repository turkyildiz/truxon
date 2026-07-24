-- R9 #106: BOL ↔ POD pairing per load. A delivered load should carry BOTH
-- road papers; #110's retention report shows fleet-wide coverage, this one
-- names the specific loads where the pair is broken (POD without BOL usually
-- means the BOL never got photographed; BOL without POD blocks invoicing and
-- is already nagged by sentinel #78 — here the office gets the worklist).
create or replace function public.doc_pairing_report(p_days int default 60)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when coalesce(auth.role(), '') = 'service_role'
              or public.my_role() in ('admin','accountant','dispatcher')
  then (
    with delivered as (
      select l.id, l.load_number, l.delivery_time,
             exists (select 1 from documents d where d.entity_type='load' and d.entity_id=l.id and d.doc_type='BOL') as has_bol,
             exists (select 1 from documents d where d.entity_type='load' and d.entity_id=l.id and d.doc_type='POD') as has_pod
      from loads l
      where l.status in ('delivered','completed')
        and l.created_at > now() - make_interval(days => p_days)
    )
    select jsonb_build_object(
      'days', p_days,
      'delivered_loads', (select count(*) from delivered),
      'paired', (select count(*) from delivered where has_bol and has_pod),
      'pod_only', (select count(*) from delivered where has_pod and not has_bol),
      'bol_only', (select count(*) from delivered where has_bol and not has_pod),
      'neither', (select count(*) from delivered where not has_bol and not has_pod),
      'broken_pairs', coalesce((
        select jsonb_agg(jsonb_build_object(
          'load_id', id, 'load_number', load_number,
          'delivered', to_char(delivery_time, 'MM/DD'),
          'missing', case when has_pod and not has_bol then 'BOL'
                          when has_bol and not has_pod then 'POD'
                          else 'BOL+POD' end)
          order by delivery_time desc nulls last)
        from (select * from delivered where not (has_bol and has_pod)
               order by delivery_time desc nulls last limit 50) x), '[]'::jsonb),
      'as_of', now())
  ) end;
$$;
revoke all on function public.doc_pairing_report(int) from public, anon;
grant execute on function public.doc_pairing_report(int) to authenticated, service_role;

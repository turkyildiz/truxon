-- Northstar: POD capture rate (playbook #271). Of loads delivered in the window,
-- the share with proof-of-delivery on file within the standard window (12h per
-- owner) — a getting-paid metric, since brokers won't pay without a timely POD.
-- POD = pod/bol/receipt/scale document on the load (case-insensitive; the web
-- panel stores 'POD'). Admin/dispatcher/accountant + service_role (for Trux).
create or replace function public.pod_capture_rate(p_start timestamptz, p_end timestamptz, p_hours int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare delivered int; captured int; have_pod int; avg_hrs numeric;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','dispatcher','accountant') then
    raise exception 'Not enough permissions';
  end if;
  with dl as (
    select l.id, l.delivery_time,
           (select min(d.uploaded_at) from public.documents d
             where d.entity_type='load' and d.entity_id=l.id
               and lower(d.doc_type) in ('pod','bol','receipt','scale')) as pod_at
      from public.loads l
     where l.status in ('delivered','completed','billed')
       and l.delivery_time >= p_start and l.delivery_time < p_end
  )
  select count(*),
         count(*) filter (where pod_at is not null and pod_at <= delivery_time + make_interval(hours => p_hours)),
         count(*) filter (where pod_at is not null),
         round(avg(extract(epoch from (pod_at - delivery_time)) / 3600.0)
                 filter (where pod_at is not null)::numeric, 1)
    into delivered, captured, have_pod, avg_hrs
    from dl;

  return jsonb_build_object(
    'window_hours', p_hours,
    'delivered_loads', delivered,
    'pod_on_file', have_pod,
    'captured_within', captured,
    'capture_rate_pct', case when delivered > 0 then round(captured::numeric / delivered * 100, 1) end,
    'pod_on_file_pct', case when delivered > 0 then round(have_pod::numeric / delivered * 100, 1) end,
    'avg_hours_to_pod', avg_hrs);
end;
$$;
revoke all on function public.pod_capture_rate(timestamptz, timestamptz, int) from public, anon;
grant execute on function public.pod_capture_rate(timestamptz, timestamptz, int) to authenticated;

-- Flip the playbook metric live (12h standard per owner).
update public.playbook_metrics
   set name = 'POD Capture Rate within 12h',
       definition = 'Loads with a POD on file within 12h of delivery ÷ delivered loads',
       target = '12h standard',
       status = 'live',
       source = 'pod_capture_rate',
       updated_at = now()
 where number = 271;

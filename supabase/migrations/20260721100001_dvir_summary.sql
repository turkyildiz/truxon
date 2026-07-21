-- Quick office view for Forest + web: DVIR compliance, last 7 days.
create or replace function public.dvir_summary(p_days int default 7)
returns table (
  driver text,
  truck text,
  inspection_type text,
  submitted_at timestamptz,
  defect boolean,
  safe boolean,
  defects text
)
language plpgsql security definer set search_path = public stable
as $$
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant', 'maintenance') then
    raise exception 'Not enough permissions';
  end if;
  return query
  select dr.full_name, t.unit_number, v.inspection_type, v.created_at,
         (exists (select 1 from jsonb_each_text(v.items) e where e.value <> 'ok')
          or v.defects <> '' or not v.safe_to_operate),
         v.safe_to_operate, v.defects
    from dvir v
    join drivers dr on dr.id = v.driver_id
    join trucks t on t.id = v.truck_id
   where v.created_at >= now() - make_interval(days => p_days)
   order by v.created_at desc;
end;
$$;
revoke all on function public.dvir_summary(int) from public, anon;
grant execute on function public.dvir_summary(int) to authenticated, service_role;

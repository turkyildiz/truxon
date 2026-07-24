-- R9 #47/#48: route-deviation detection + out-of-route cost. We don't get a
-- planned Valhalla polyline per load, but we have two honest anchors: the
-- BOOKED miles (what we quoted/paid on) and the GPS trail actually driven
-- (sum of breadcrumb-to-breadcrumb great-circle hops). When the driven miles
-- run materially over booked, that gap is out-of-route — priced at the GL
-- all-in $/mi so a wandering lane shows up as dollars, not just a squiggle.
create or replace function public.route_deviation_report(p_days int default 30, p_min_pct numeric default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
  v_rpm numeric := coalesce((public.fleet_cost_basis()->>'gl_all_in_rpm')::numeric, 0);
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with base as (
    select l.id, l.load_number, c.company_name as customer, l.miles as booked_miles,
           l.truck_id,
           coalesce(l.pickup_time, l.created_at) - interval '2 hours' as w_from,
           coalesce(l.delivery_time, l.created_at) + interval '4 hours' as w_to
      from loads l join customers c on c.id = l.customer_id
     where l.status in ('completed','billed') and l.truck_id is not null
       and coalesce(l.miles, 0) > 0
       and coalesce(l.delivery_time, l.created_at) > now() - make_interval(days => p_days)
  ), driven as (
    select b.*, (
      select sum(public.trux_miles(p.lat, p.lng, p.plat, p.plon))
        from (
          select h.lat, h.lng,
                 lag(h.lat) over (order by h.ts) as plat,
                 lag(h.lng) over (order by h.ts) as plon
            from eld_location_history h
           where h.truck_id = b.truck_id and h.ts between b.w_from and b.w_to
             and h.lat is not null and h.lng is not null
        ) p where p.plat is not null
    ) as driven_miles
    from base b
  ), scored as (
    select *, round(driven_miles, 0) as dm,
           round(driven_miles - booked_miles, 0) as extra,
           case when booked_miles > 0 then round((driven_miles - booked_miles) / booked_miles * 100, 1) end as pct
      from driven where driven_miles is not null and driven_miles > booked_miles
  )
  select jsonb_build_object(
    'days', p_days, 'min_pct', p_min_pct, 'all_in_rpm', v_rpm,
    'loads_measured', (select count(*) from driven where driven_miles is not null),
    'flagged', (select count(*) from scored where pct >= p_min_pct),
    'total_out_of_route_miles', (select coalesce(round(sum(extra), 0), 0) from scored where pct >= p_min_pct),
    'total_out_of_route_cost', (select coalesce(round(sum(extra) * v_rpm, 2), 0) from scored where pct >= p_min_pct),
    'worst', coalesce((select jsonb_agg(jsonb_build_object(
        'load_number', s.load_number, 'customer', s.customer,
        'booked_miles', s.booked_miles, 'driven_miles', s.dm,
        'out_of_route_miles', s.extra, 'out_of_route_pct', s.pct,
        'cost', round(s.extra * v_rpm, 2)) order by s.extra desc)
      from (select * from scored where pct >= p_min_pct order by extra desc limit 15) s), '[]'::jsonb),
    'note', 'driven miles = GPS breadcrumb path (great-circle hops); planned = booked miles. Loads without breadcrumb coverage are excluded, not counted as zero-deviation.',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.route_deviation_report(int, numeric) from public, anon, authenticated;
grant execute on function public.route_deviation_report(int, numeric) to authenticated, service_role;

-- R9 #59: GPS-confirmed delivery → auto-suggest a POD request. A delivered
-- load whose truck's breadcrumbs sat within ~0.75mi of the consignee geocode
-- around the appointment IS confirmed on the ground — so if no POD is on file,
-- that is exactly the load to chase paper on (we know it delivered; we just
-- lack the signature). Excludes loads with no delivery geocode or no coverage.
create or replace function public.gps_confirmed_missing_pod(p_days int default 21, p_radius_mi numeric default 0.75)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with cand as (
    select l.id, l.load_number, c.company_name as customer, l.delivery_time, l.delivery_address,
           l.truck_id, l.delivery_lat, l.delivery_lon
      from loads l join customers c on c.id = l.customer_id
     where l.status in ('delivered','completed','billed') and l.truck_id is not null
       and l.delivery_lat is not null and l.delivery_time is not null
       and l.delivery_time > now() - make_interval(days => p_days)
       and not exists (select 1 from documents d
                        where d.entity_type = 'load' and d.entity_id = l.id and d.doc_type = 'POD')
  ), confirmed as (
    select cand.*, (
      select min(public.trux_miles(cand.delivery_lat, cand.delivery_lon, h.lat, h.lng))
        from eld_location_history h
       where h.truck_id = cand.truck_id and h.lat is not null
         and h.ts between cand.delivery_time - interval '12 hours' and cand.delivery_time + interval '12 hours'
    ) as closest_mi
    from cand
  )
  select jsonb_build_object(
    'days', p_days, 'radius_mi', p_radius_mi,
    'confirmed_missing_pod', coalesce((select jsonb_agg(jsonb_build_object(
        'load_number', x.load_number, 'customer', x.customer,
        'delivered', x.delivery_time, 'address', x.delivery_address,
        'closest_mi', round(x.closest_mi, 2)) order by x.delivery_time desc)
      from confirmed x where x.closest_mi is not null and x.closest_mi <= p_radius_mi), '[]'::jsonb),
    'note', 'GPS put the truck at the consignee but no POD is filed — the delivery happened, chase the signature. Loads without a delivery geocode or breadcrumb coverage are not listed.',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.gps_confirmed_missing_pod(int, numeric) from public, anon, authenticated;
grant execute on function public.gps_confirmed_missing_pod(int, numeric) to authenticated, service_role;

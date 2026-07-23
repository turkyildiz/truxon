-- R9 #51/#61: dock-time league table. Every GPS-measured stop grouped by
-- facility (customer + state + stop side): average / P50 / P90 dwell and the
-- detention it cost — the exhibit for "your dock holds our trucks" rate
-- conversations.
create or replace function public.facility_dwell_league(p_days int default 45)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_rows jsonb;
begin
  -- positive-form gate: null auth.role() (direct SQL) must NOT slip through
  -- the negated idiom
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select jsonb_agg(t order by t.detention_hours desc nulls last) into v_rows from (
    select d.customer, d.stop_state, d.stop_type,
           count(*) as stops,
           round(avg(d.dwell_min) / 60.0, 1) as avg_dwell_h,
           round(percentile_disc(0.5) within group (order by d.dwell_min) / 60.0, 1) as p50_h,
           round(percentile_disc(0.9) within group (order by d.dwell_min) / 60.0, 1) as p90_h,
           round(sum(greatest(d.detention_min, 0)) / 60.0, 1) as detention_hours,
           round(sum(greatest(d.est_pay, 0)), 2) as detention_dollars
      from public.detention_events(p_days) d
     group by d.customer, d.stop_state, d.stop_type
    having count(*) >= 2) t;
  return jsonb_build_object(
    'days', p_days,
    'facilities', coalesce(v_rows, '[]'::jsonb),
    'as_of', now());
end;
$$;
revoke all on function public.facility_dwell_league(int) from public, anon;
grant execute on function public.facility_dwell_league(int) to authenticated, service_role;

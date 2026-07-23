-- R9 #56: speeding trend — minutes at 75+ per truck THIS week vs LAST week
-- (Mon-Sun standard), so coaching sees direction, not just totals.
create or replace function public.speeding_trend()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_ws date := public.trux_week_start(current_date);
  v_rows jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with pts as (
    select truck_id, ts, speed,
           extract(epoch from (lead(ts) over (partition by truck_id order by ts) - ts)) as gap_s
      from eld_location_history
     where truck_id is not null and speed is not null
       and ts >= v_ws - 7
  ), w as (
    select truck_id, ts, least(gap_s, 900) as sec, speed
      from pts where gap_s is not null and gap_s between 1 and 900 and speed >= 75
  ), per as (
    select truck_id,
           round(sum(sec) filter (where ts >= v_ws) / 60.0, 1) as this_week_min,
           round(sum(sec) filter (where ts < v_ws) / 60.0, 1) as last_week_min
      from w group by truck_id
  )
  select jsonb_agg(jsonb_build_object(
      'unit', t.unit_number,
      'this_week_min', coalesce(p.this_week_min, 0),
      'last_week_min', coalesce(p.last_week_min, 0),
      'delta_min', round(coalesce(p.this_week_min, 0) - coalesce(p.last_week_min, 0), 1))
      order by coalesce(p.this_week_min, 0) desc) into v_rows
    from per p join trucks t on t.id = p.truck_id;
  return jsonb_build_object(
    'week_start', v_ws,
    'trucks', coalesce(v_rows, '[]'::jsonb),
    'note', 'minutes at 75+ mph from ELD pings; last week may under-read where the bank has gaps',
    'as_of', now());
end;
$$;
revoke all on function public.speeding_trend() from public, anon;
grant execute on function public.speeding_trend() to authenticated, service_role;

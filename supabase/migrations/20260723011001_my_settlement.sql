-- R9 #143/#144: driver settlement statement — the caller's OWN pay, itemized
-- per load for any week (Mon-Sun standard): lane, loaded/empty miles, and the
-- pay math for that load. Company revenue deliberately excluded, same as the
-- self-scorecard. Doubles as the driver's load history.
create or replace function public.my_settlement(p_week_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  ws date := public.trux_week_start(current_date) - (7 * greatest(least(p_week_offset, 26), 0));
  we date;
  v_driver_id bigint;
  v_rows jsonb;
  v_total numeric;
begin
  select d.id into v_driver_id from drivers d where d.user_id = auth.uid();
  if v_driver_id is null then
    return null;  -- office user or unlinked login
  end if;
  we := ws + 7;

  select jsonb_agg(t order by t.delivered), round(coalesce(sum(t.pay), 0), 2)
    into v_rows, v_total
    from (
      select l.load_number,
             l.delivery_time::date as delivered,
             coalesce(nullif(trim(split_part(l.pickup_address, ',', 2)), ''), l.pickup_state, '?')
               || ' → ' ||
             coalesce(nullif(trim(split_part(l.delivery_address, ',', 2)), ''), l.delivery_state, '?') as lane,
             round(l.miles, 0) as miles,
             round(coalesce(l.empty_miles, 0), 0) as empty_miles,
             round(l.miles * d.pay_per_mile
               + case when d.empty_miles_paid then coalesce(l.empty_miles, 0) * d.pay_per_empty_mile else 0 end, 2) as pay
        from loads l
        join drivers d on d.id = l.driver_id
       where l.driver_id = v_driver_id
         and l.status in ('completed', 'billed')
         and l.delivery_time >= ws and l.delivery_time < we) t;

  return jsonb_build_object(
    'week_start', ws, 'week_end', we - 1,
    'week_label', public.trux_week_label(ws),
    'loads', coalesce(v_rows, '[]'::jsonb),
    'total_pay', coalesce(v_total, 0),
    'note', 'estimated from your per-mile rate; the office settlement is final');
end;
$$;
revoke all on function public.my_settlement(int) from public, anon;
grant execute on function public.my_settlement(int) to authenticated;

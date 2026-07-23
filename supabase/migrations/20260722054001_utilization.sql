-- R9 #54/#55: truck-day utilization. Per unit over the window: days the ELD
-- says it moved (>5 mi) vs days it sat, revenue earned, revenue per moving
-- day, and the weekend share of its miles. Zero-marker days (confirmed
-- parked) count as sitting; unbanked days are excluded from the denominator
-- rather than guessed.
create or replace function public.truck_utilization(p_days int default 28)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_rows jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select jsonb_agg(t order by t.moving_days desc, t.revenue desc) into v_rows from (
    select tk.unit_number as unit,
           count(*) filter (where em.miles > 5) as moving_days,
           count(*) filter (where em.miles <= 5) as parked_days,
           count(*) as banked_days,
           round(sum(em.miles) filter (where extract(isodow from em.day) in (6,7))
                 / nullif(sum(em.miles), 0) * 100, 0) as weekend_miles_pct,
           coalesce(r.revenue, 0) as revenue,
           case when count(*) filter (where em.miles > 5) > 0
             then round(coalesce(r.revenue, 0) / count(*) filter (where em.miles > 5), 0) end
             as revenue_per_moving_day
      from trucks tk
      join eld_daily_miles em on em.truck_id = tk.id and em.state = ''
       and em.day >= current_date - p_days and em.day < current_date
      left join lateral (
        select round(sum(l.rate), 2) revenue from loads l
         where l.truck_id = tk.id and l.status in ('completed','billed')
           and l.delivery_time >= current_date - p_days) r on true
     where tk.status <> 'retired'
     group by tk.id, tk.unit_number, r.revenue) t;
  return jsonb_build_object(
    'days', p_days,
    'trucks', coalesce(v_rows, '[]'::jsonb),
    'note', 'moving = ELD-banked day >5 mi; unbanked days excluded, not guessed',
    'as_of', now());
end;
$$;
revoke all on function public.truck_utilization(int) from public, anon;
grant execute on function public.truck_utilization(int) to authenticated, service_role;

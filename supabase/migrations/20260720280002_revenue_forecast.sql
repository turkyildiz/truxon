-- Northstar predictive layer, gear 1 (cont.) — weekly revenue outlook.
-- Blends a trailing 8-week moving average with the same week LAST year (real
-- seasonality, thanks to the standard week) so a light/heavy season is expected,
-- not a surprise. Also reports fleet utilization (loads per active truck).
--   revenue_forecast(weeks) — projected revenue + basis per upcoming week
-- Admin/dispatcher/accountant.

create or replace function public.revenue_forecast(p_weeks int default 6)
returns table (
  week_start date, week_number int, week_label text,
  forecast_revenue numeric, trailing_avg numeric, last_year_revenue numeric,
  loads_per_truck numeric, basis text
)
language plpgsql security definer set search_path = public stable as $$
declare
  v_trailing numeric;
  v_active_trucks int;
  v_trailing_loads numeric;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  -- trailing 8 completed weeks (exclude the current partial week)
  select coalesce(round(avg(rev), 2), 0), coalesce(round(avg(lds), 2), 0)
    into v_trailing, v_trailing_loads
  from (
    select public.trux_week_start(l.delivery_time::date) as ws,
           sum(l.rate) as rev, count(*) as lds
      from public.loads l
     where l.status in ('completed', 'billed')
       and l.delivery_time::date < public.trux_week_start(current_date)
       and l.delivery_time > now() - interval '120 days'
     group by 1
     order by ws desc
     limit 8
  ) t;

  select count(*) into v_active_trucks from public.trucks where status <> 'retired';

  return query
  with weeks as (
    select public.trux_week_start(current_date) + (g * 7) as ws
    from generate_series(0, greatest(p_weeks, 1) - 1) g
  ),
  hist as (
    select public.trux_week_start(l.delivery_time::date) as ws, sum(l.rate) as rev
      from public.loads l
     where l.status in ('completed', 'billed') and l.delivery_time > now() - interval '430 days'
     group by 1
  )
  select w.ws,
         public.trux_week_number(w.ws),
         public.trux_week_label(w.ws),
         case when ly.rev is not null then round(0.6 * v_trailing + 0.4 * ly.rev, 2)
              else round(v_trailing, 2) end as forecast_revenue,
         v_trailing as trailing_avg,
         ly.rev as last_year_revenue,
         case when v_active_trucks > 0 then round(v_trailing_loads / v_active_trucks, 2) else null end as loads_per_truck,
         case when ly.rev is not null then 'trailing avg + same week last year'
              else 'trailing 8-week average' end as basis
  from weeks w
  left join lateral (
    select h.rev from hist h
     where h.ws = (select r.week_start
                     from public.trux_week_range(public.trux_week_year(w.ws) - 1, public.trux_week_number(w.ws)) r)
     limit 1
  ) ly on true
  order by w.ws;
end;
$$;
revoke all on function public.revenue_forecast(int) from public, anon;
grant execute on function public.revenue_forecast(int) to authenticated;

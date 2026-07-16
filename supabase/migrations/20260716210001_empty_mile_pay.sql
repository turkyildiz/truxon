-- Empty-mile driver pay (owner 2026-07-16: "we always want to pay our
-- drivers"). Per-driver opt-in checkbox + rate; the weekly settlement
-- includes empty miles for drivers that have it enabled.

alter table public.drivers
  add column if not exists empty_miles_paid boolean not null default false;

-- Drivers migrated from ITS with an empty-mile rate were being paid for
-- empty miles there — keep paying them.
update public.drivers set empty_miles_paid = true where pay_per_empty_mile > 0;

-- weekly_report: driver pay = loaded/total miles × rate, plus empty miles ×
-- empty rate when the driver's checkbox is on.
create or replace function public.weekly_report(p_week_of date default current_date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := p_week_of - ((extract(isodow from p_week_of))::int - 1);
  wk_end date := wk_start + 6;
  result jsonb;
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  with wk_loads as (
    select l.*
      from public.loads l
     where l.status in ('completed', 'billed')
       and l.delivery_time >= wk_start::timestamptz
       and l.delivery_time < (wk_end + 1)::timestamptz
  ),
  by_truck as (
    select t.id as key_id, t.unit_number as name,
           count(*)::int as loads, sum(w.miles) as miles, sum(w.rate) as revenue,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile
      from wk_loads w join public.trucks t on t.id = w.truck_id
     group by t.id, t.unit_number
  ),
  by_driver as (
    select d.id as key_id, d.full_name as name,
           count(*)::int as loads, sum(w.miles) as miles, sum(w.rate) as revenue,
           sum(w.empty_miles) as empty_miles,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile,
           round(sum(w.miles) * d.pay_per_mile
                 + case when d.empty_miles_paid then coalesce(sum(w.empty_miles), 0) * d.pay_per_empty_mile else 0 end,
             2) as driver_pay
      from wk_loads w join public.drivers d on d.id = w.driver_id
     group by d.id, d.full_name, d.pay_per_mile, d.pay_per_empty_mile, d.empty_miles_paid
  )
  select jsonb_build_object(
    'week_start', wk_start,
    'week_end', wk_end,
    'by_truck', coalesce((select jsonb_agg(to_jsonb(bt) order by bt.revenue desc) from by_truck bt), '[]'::jsonb),
    'by_driver', coalesce((select jsonb_agg(to_jsonb(bd) order by bd.revenue desc) from by_driver bd), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'loads', count(*)::int,
        'miles', coalesce(sum(miles), 0),
        'revenue', coalesce(sum(rate), 0),
        'avg_rate_per_mile', case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end
      ) from wk_loads)
  ) into result;

  return result;
end;
$$;

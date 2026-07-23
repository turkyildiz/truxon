-- Second refinement on 020003: span-matching fixed the bank-start mismatch but
-- not MID-SPAN gap days — several ELDs skip days (unit 08 tracked 5 of 23),
-- and fuel bought on an untracked day still counted against zero miles,
-- keeping variances at fantasy levels (14: +318%). Same cure as truck_mpg's
-- day-matching: for an ELD-basis truck, a gallon counts toward the ratio only
-- if that truck banked GPS miles that day; off-day gallons are reported
-- separately (gallons_untracked) — the eld_dark sentinel owns the "why is
-- this truck fueling while its ELD is dark" half of the story.
drop function if exists public.fuel_efficiency_by_truck(int);
create function public.fuel_efficiency_by_truck(p_days int default 45)
returns table (
  truck_id bigint, unit_number text,
  loaded_miles numeric, deadhead_miles numeric, total_miles numeric,
  gallons numeric, implied_mpg numeric, expected_gallons numeric, gallon_variance_pct numeric,
  diesel_spend numeric, nonfuel_spend numeric, nondiesel_gallons numeric,
  eld_miles numeric, miles_basis text, gallons_untracked numeric
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  return query
  with mi as (
    select l.truck_id as tid,
           sum(coalesce(l.miles,0))       as loaded,
           sum(coalesce(l.empty_miles,0)) as deadhead
      from public.loads l
     where l.status in ('completed','billed')
       and l.delivery_time > now() - make_interval(days => p_days)
       and l.truck_id is not null
     group by l.truck_id
  ), em as (
    select e.truck_id as tid, sum(e.miles) as mi
      from public.eld_daily_miles e
     where e.day > current_date - p_days and e.truck_id is not null
     group by e.truck_id
  ), basis as (
    select t.id as bid, t.unit_number as unit,
           coalesce(mi.loaded,0) as loaded, coalesce(mi.deadhead,0) as deadhead,
           coalesce(em.mi,0) as eld_mi,
           case when coalesce(em.mi,0) > 0 then em.mi
                else coalesce(mi.loaded,0)+coalesce(mi.deadhead,0) end as tot,
           case when coalesce(em.mi,0) > 0 then 'eld' else 'booked' end as mb
      from public.trucks t
      left join mi on mi.tid = t.id
      left join em on em.tid = t.id
     where t.status <> 'retired'
  ), fu as (
    select b.bid as tid,
           coalesce(sum(f.gallons) filter (where coalesce(f.gallons,0)>0
             and (b.mb = 'booked' or exists (
               select 1 from public.eld_daily_miles e
                where e.truck_id = b.bid and e.day = f.transaction_time::date))),0) as gal,
           coalesce(sum(f.gallons) filter (where coalesce(f.gallons,0)>0
             and b.mb = 'eld' and not exists (
               select 1 from public.eld_daily_miles e
                where e.truck_id = b.bid and e.day = f.transaction_time::date)),0) as gal_untracked,
           coalesce(sum(f.amount)  filter (where coalesce(f.gallons,0)>0),0) as diesel_spend,
           coalesce(sum(f.amount)  filter (where coalesce(f.gallons,0)=0 and f.amount>0),0) as nonfuel,
           coalesce(sum(f.gallons) filter (where lower(coalesce(f.fuel_type,'')) ~ '(unleaded|ethanol|gasoline|premium|regular|e85|midgrade)'),0) as nondiesel_gal
      from basis b
      join public.fuel_transactions f
        on f.truck_id = b.bid
       and f.transaction_time > now() - make_interval(days => p_days)
     group by b.bid
  )
  select b.bid, b.unit,
         b.loaded, b.deadhead, b.tot,
         coalesce(fu.gal,0),
         case when coalesce(fu.gal,0) > 0 and b.tot > 0 then round(b.tot/fu.gal, 2) end,
         round(b.tot/6.5),
         case when b.tot > 0
              then round((coalesce(fu.gal,0)/nullif(b.tot/6.5,0)-1)*100) end,
         coalesce(fu.diesel_spend,0), coalesce(fu.nonfuel,0), coalesce(fu.nondiesel_gal,0),
         round(b.eld_mi), b.mb, coalesce(fu.gal_untracked,0)
    from basis b
    left join fu on fu.tid = b.bid
   order by 9 desc nulls last;
end;
$$;
revoke execute on function public.fuel_efficiency_by_truck(int) from public, anon;
grant execute on function public.fuel_efficiency_by_truck(int) to authenticated, service_role;

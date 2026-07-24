-- R9 #129: quote pricing feedback. The pipeline already measures win rate;
-- this records WHAT we quoted and compares won/lost premiums against our own
-- booked lane average — "we lose lanes we price 30% over our own book" is a
-- sentence the win-rate number alone can never say. Premium is vs our book,
-- not "the market" — we don't have the market, and don't pretend to.
alter table public.quote_requests
  add column if not exists quoted_rate numeric(10,2),
  add column if not exists quoted_at timestamptz,
  add column if not exists lost_reason text not null default '';

create or replace function public.quote_pricing_report(p_days int default 180)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with decided as (
    select q.*, upper(q.origin_state) as o, upper(q.dest_state) as d
      from quote_requests q
     where q.status in ('won','lost')
       and q.created_at > now() - make_interval(days => p_days)
  ), priced as (
    select dd.*, lane.lane_avg, lane.lane_n,
           case when lane.lane_avg > 0 and dd.quoted_rate is not null
                then round((dd.quoted_rate - lane.lane_avg) / lane.lane_avg * 100, 1)
           end as premium_pct
      from decided dd
      left join lateral (
        select round(avg(l.rate), 2) as lane_avg, count(*) as lane_n
          from loads l
         where l.status in ('completed','billed')
           and upper(l.pickup_state) = dd.o and upper(l.delivery_state) = dd.d
           and dd.o <> '' and dd.d <> '') lane on true
  )
  select jsonb_build_object(
    'days', p_days,
    'decided', (select count(*) from decided),
    'no_rate_recorded', (select count(*) from decided where quoted_rate is null),
    'no_lane_history', (select count(*) from priced where quoted_rate is not null and premium_pct is null),
    'won', jsonb_build_object(
      'n', (select count(*) from priced where status = 'won' and premium_pct is not null),
      'avg_premium_pct', (select round(avg(premium_pct), 1) from priced where status = 'won' and premium_pct is not null)),
    'lost', jsonb_build_object(
      'n', (select count(*) from priced where status = 'lost' and premium_pct is not null),
      'avg_premium_pct', (select round(avg(premium_pct), 1) from priced where status = 'lost' and premium_pct is not null),
      'top_reasons', coalesce((select jsonb_agg(jsonb_build_object('reason', r.lost_reason, 'n', r.n) order by r.n desc, r.lost_reason)
        from (select lost_reason, count(*) n from decided
               where status = 'lost' and lost_reason <> ''
               group by lost_reason order by count(*) desc, lost_reason limit 5) r), '[]'::jsonb)),
    'lanes', coalesce((select jsonb_agg(jsonb_build_object(
        'lane', x.o||'→'||x.d, 'won', x.won_n, 'lost', x.lost_n,
        'avg_quoted', x.avg_q, 'our_lane_avg', x.lane_avg) order by (x.won_n + x.lost_n) desc)
      from (select o, d, lane_avg,
                   count(*) filter (where status='won') won_n,
                   count(*) filter (where status='lost') lost_n,
                   round(avg(quoted_rate), 0) avg_q
              from priced where premium_pct is not null
             group by o, d, lane_avg limit 10) x), '[]'::jsonb),
    'note', 'premium vs OUR booked lane average (not the market); quotes without a recorded rate or lane history are counted, not hidden',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.quote_pricing_report(int) from public, anon, authenticated;
grant execute on function public.quote_pricing_report(int) to authenticated, service_role;

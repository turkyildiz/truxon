-- R9 #132/#135: two customer/revenue reports.
-- #132 rate-con turnaround: how fast paper becomes a booked load. Positive
--   delta = rate con uploaded first, then booked (real turnaround); ~zero =
--   extracted at booking (the AI flow); negative = booked on a phone call,
--   paper chased later. All three buckets reported — no pretending the
--   negative bucket is speed.
-- #135 lost-customer post-mortem: who used to ship and went quiet. "Lost"
--   is earned honestly: quiet longer than BOTH the stale threshold and 2x
--   the customer's own historical cadence, so slow-but-steady shippers
--   don't get eulogized.
create or replace function public.ratecon_turnaround_report(p_days int default 90)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with w as (
    select l.id, l.load_number, l.created_at as booked_at,
           (select min(d.uploaded_at) from documents d
             where d.entity_type = 'load' and d.entity_id = l.id
               and d.doc_type = 'Rate Confirmation') as ratecon_at
      from loads l
     where l.created_at > now() - make_interval(days => p_days)
       and l.status <> 'cancelled'
  ), t as (
    select *, extract(epoch from (booked_at - ratecon_at)) / 3600.0 as delta_h from w
  )
  select jsonb_build_object(
    'days', p_days,
    'loads', (select count(*) from t),
    'no_ratecon', (select count(*) from t where ratecon_at is null),
    'extracted_at_booking', (select count(*) from t where abs(delta_h) <= 0.25),
    'paper_first', jsonb_build_object(
      'n', (select count(*) from t where delta_h > 0.25),
      'median_hours', (select round((percentile_cont(0.5) within group (order by delta_h))::numeric, 1)
                         from t where delta_h > 0.25),
      'worst_hours', (select round(max(delta_h)::numeric, 1) from t where delta_h > 0.25)),
    'booked_before_paper', (select count(*) from t where delta_h < -0.25),
    'note', 'delta = load created minus earliest Rate Confirmation upload; |delta|<=15min counts as extracted-at-booking; booked-before-paper is phone bookings, not speed',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.ratecon_turnaround_report(int) from public, anon, authenticated;
grant execute on function public.ratecon_turnaround_report(int) to authenticated, service_role;

create or replace function public.lost_customer_report(p_stale_days int default 45, p_lookback_days int default 365)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with hist as (
    select c.id, c.company_name,
           count(*) as loads_n,
           sum(l.rate) as revenue,
           max(coalesce(l.delivery_time, l.created_at)) as last_load_at,
           min(coalesce(l.delivery_time, l.created_at)) as first_load_at,
           count(*) filter (where l.status = 'cancelled') as cancels
      from customers c
      join loads l on l.customer_id = c.id
     where l.created_at > now() - make_interval(days => p_lookback_days)
     group by c.id, c.company_name
    having count(*) >= 2
  ), scored as (
    select *,
           extract(epoch from (now() - last_load_at)) / 86400.0 as days_quiet,
           extract(epoch from (last_load_at - first_load_at)) / 86400.0
             / greatest(loads_n - 1, 1) as avg_gap_days
      from hist
  )
  select jsonb_build_object(
    'stale_days', p_stale_days, 'lookback_days', p_lookback_days,
    'lost', coalesce((select jsonb_agg(jsonb_build_object(
        'customer', s.company_name,
        'last_load', s.last_load_at::date,
        'days_quiet', round(s.days_quiet::numeric, 0),
        'usual_gap_days', round(s.avg_gap_days::numeric, 0),
        'loads', s.loads_n,
        'trailing_revenue', round(s.revenue, 2),
        'cancels', s.cancels)
        order by s.revenue desc)
      from scored s
     where s.days_quiet > p_stale_days
       and s.days_quiet > 2 * s.avg_gap_days), '[]'::jsonb),
    'note', 'lost = quiet longer than the threshold AND 2x the customer''s own booking cadence; revenue is booked rate over the lookback',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.lost_customer_report(int, int) from public, anon, authenticated;
grant execute on function public.lost_customer_report(int, int) to authenticated, service_role;

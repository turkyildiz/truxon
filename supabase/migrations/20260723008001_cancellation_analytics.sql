-- R9 #125: load cancellation analytics — who cancels, how often, and what it
-- costs. Cancellation rate per customer (of their booked loads), the revenue
-- that walked, and the fleet totals; feeds the keep-or-fire conversation.
create or replace function public.cancellation_analytics(p_days int default 90)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  with w as (
    select l.*, c.company_name
      from loads l join customers c on c.id = l.customer_id
     where l.created_at > now() - make_interval(days => p_days)
  )
  select jsonb_build_object(
    'days', p_days,
    'booked', (select count(*) from w),
    'cancelled', (select count(*) from w where status = 'cancelled'),
    'cancel_rate_pct', (select round(100.0 * count(*) filter (where status = 'cancelled')
                          / nullif(count(*), 0), 1) from w),
    'revenue_walked', (select round(coalesce(sum(rate) filter (where status = 'cancelled'), 0), 2) from w),
    'by_customer', coalesce((select jsonb_agg(jsonb_build_object(
        'customer', x.company_name, 'booked', x.n, 'cancelled', x.canc,
        'rate_pct', round(100.0 * x.canc / x.n, 1), 'revenue_walked', x.lost)
        order by x.canc desc, x.lost desc)
      from (select company_name, count(*) n,
                   count(*) filter (where status = 'cancelled') canc,
                   round(coalesce(sum(rate) filter (where status = 'cancelled'), 0), 2) lost
              from w group by company_name
            having count(*) filter (where status = 'cancelled') > 0) x), '[]'::jsonb),
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.cancellation_analytics(int) from public, anon;
grant execute on function public.cancellation_analytics(int) to authenticated, service_role;

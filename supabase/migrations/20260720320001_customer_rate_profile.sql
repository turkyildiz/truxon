-- Northstar margin sharpener: what this broker has actually paid us. The load
-- margin panel judges a rate against the fleet's breakeven; this adds the other
-- half a dispatcher negotiates on — the broker's own trailing rate history, so
-- an offer can be read as above/below what this customer usually pays per mile.
-- Trailing 180 days of completed/billed loads with real miles + rate.
-- Admin/dispatcher/accountant (matches fleet_cost_basis / the dispatch surface).
create or replace function public.customer_rate_profile(p_customer_id bigint)
returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare v jsonb;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select jsonb_build_object(
           'load_count', count(*),
           'avg_rpm',    round(avg(l.rate / l.miles), 2),
           'median_rpm', round((percentile_cont(0.5) within group (order by l.rate / l.miles))::numeric, 2),
           'avg_rate',   round(avg(l.rate), 0),
           'avg_miles',  round(avg(l.miles), 0),
           'last_rpm',   round((array_agg(l.rate / l.miles order by l.delivery_time desc))[1], 2))
    into v
    from public.loads l
   where l.customer_id = p_customer_id
     and l.status in ('completed', 'billed')
     and l.miles > 0 and l.rate > 0
     and l.delivery_time > now() - interval '180 days';

  return coalesce(v, jsonb_build_object('load_count', 0));
end;
$$;
revoke all on function public.customer_rate_profile(bigint) from public, anon;
grant execute on function public.customer_rate_profile(bigint) to authenticated;

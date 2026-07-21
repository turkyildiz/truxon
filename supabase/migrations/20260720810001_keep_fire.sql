-- R3 #7 — the playbook's quarterly keep-or-fire decision, computed. Rules are
-- explicit and printed in each row's reason:
--   fire      margin < 0 AND pays > 90 days (losing money financing them)
--   fix-price margin < 0 (freight is fine, the rate is not)
--   grow      margin >= 10% at the GL all-in cost AND pays <= 60 days
--   keep      everything else
create function public.customer_keep_fire(p_days int default 365)
returns table (
  customer_id bigint,
  company_name text,
  revenue numeric,
  loads int,
  margin numeric,
  margin_pct numeric,
  avg_days_to_pay numeric,
  detention_hours numeric,
  revenue_share_pct numeric,
  recommendation text,
  reason text
)
language plpgsql security definer set search_path = public stable
as $$
declare
  v_rpm numeric := coalesce(((public.fleet_cost_basis())->>'gl_all_in_rpm')::numeric, 0);
  v_total numeric;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(l.rate), 0) into v_total
    from loads l
   where l.status in ('completed', 'billed')
     and l.delivery_time >= now() - make_interval(days => p_days);

  return query
  with base as (
    select l.customer_id as cid,
           sum(l.rate) as rev,
           count(*)::int as n,
           sum(l.rate) - sum(l.miles) * v_rpm as marg,
           coalesce(sum(a.minutes) / 60.0, 0) as det_hrs
      from loads l
      left join load_accessorials a
             on a.load_id = l.id and a.atype = 'detention'
     where l.status in ('completed', 'billed')
       and l.delivery_time >= now() - make_interval(days => p_days)
     group by l.customer_id
  )
  select b.cid, c.company_name,
         round(b.rev), b.n, round(b.marg),
         case when b.rev > 0 then round(100 * b.marg / b.rev, 1) end,
         p.avg_days,
         round(b.det_hrs, 1),
         case when v_total > 0 then round(100 * b.rev / v_total, 1) end,
         case
           when b.marg < 0 and coalesce(p.avg_days, 0) > 90 then 'fire'
           when b.marg < 0 then 'fix-price'
           when b.rev > 0 and b.marg / b.rev >= 0.10 and coalesce(p.avg_days, 999) <= 60 then 'grow'
           else 'keep'
         end,
         concat_ws('; ',
           case when b.marg < 0
                then format('loses $%s at the $%s/mi all-in cost', abs(round(b.marg)), v_rpm) end,
           case when coalesce(p.avg_days, 0) > 90
                then format('pays in %s days', round(p.avg_days)) end,
           case when b.rev > 0 and b.marg / b.rev >= 0.10
                then format('%s%% margin', round(100 * b.marg / b.rev, 1)) end,
           case when b.det_hrs / greatest(b.n, 1) > 2
                then format('%s detention hrs across %s loads', round(b.det_hrs, 1), b.n) end,
           case when v_total > 0 and b.rev / v_total > 0.25
                then format('%s%% of all revenue — concentration risk', round(100 * b.rev / v_total, 1)) end)
  from base b
  join customers c on c.id = b.cid
  left join lateral (
    select pp.avg_days from public.customer_pay_profile() pp where pp.customer_id = b.cid
  ) p on true
  order by b.marg asc;
end;
$$;
revoke all on function public.customer_keep_fire(int) from public, anon;
grant execute on function public.customer_keep_fire(int) to authenticated, service_role;

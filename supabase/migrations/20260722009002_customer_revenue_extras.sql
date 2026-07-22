-- Playbook march, Revenue cluster (R7 block 2). Built on customer_keep_fire's
-- per-customer margin (revenue at the GL all-in cost per mile) + first-load
-- dates. Contract/spot/dedicated mix stays needs_data honestly — there's no
-- rate-type flag on loads.
create or replace function public.customer_revenue_extras(p_days int default 365)
returns jsonb
language plpgsql security definer set search_path = public stable
as $$
declare
  v_total int; v_unprofitable int;
  v_top_profit numeric; v_bottom_profit numeric; v_all_profit numeric;
  v_decile int;
  v_avg_years numeric;
begin
  if auth.uid() is not null and public.my_role() not in ('admin','accountant') then
    raise exception 'Not enough permissions';
  end if;

  select count(*), count(*) filter (where margin < 0), coalesce(sum(margin), 0)
    into v_total, v_unprofitable, v_all_profit
    from public.customer_keep_fire(p_days);

  v_decile := greatest(1, (v_total / 10));

  select coalesce(sum(margin), 0) into v_top_profit
    from (select margin from public.customer_keep_fire(p_days) order by margin desc limit v_decile) t;
  select coalesce(sum(margin), 0) into v_bottom_profit
    from (select margin from public.customer_keep_fire(p_days) order by margin asc limit v_decile) b;

  -- average customer relationship length (first load → now), years
  select round(avg(extract(epoch from (now() - fl)) / 31557600.0)::numeric, 2) into v_avg_years
    from (select customer_id, min(created_at) fl from public.loads group by customer_id) f;

  return jsonb_build_object(
    'unprofitable_customer_count', v_unprofitable,
    'customers_scored', v_total,
    'top_decile_profit_pct', case when v_all_profit > 0 then round(v_top_profit / v_all_profit * 100, 1) end,
    'top_decile_profit', round(v_top_profit, 2),
    'bottom_decile_profit', round(v_bottom_profit, 2),
    'avg_relationship_years', v_avg_years,
    'decile_size', v_decile,
    'as_of', now()
  );
end;
$$;
revoke all on function public.customer_revenue_extras(int) from public, anon;
grant execute on function public.customer_revenue_extras(int) to authenticated, service_role;

update public.playbook_metrics set status='live', source='customer_revenue_extras().unprofitable_customer_count', updated_at=now() where number = 410;
update public.playbook_metrics set status='live', source='customer_revenue_extras().top_decile_profit_pct',      updated_at=now() where number = 408;
update public.playbook_metrics set status='live', source='customer_revenue_extras().bottom_decile_profit',       updated_at=now() where number = 409;
update public.playbook_metrics set status='live', source='customer_revenue_extras().avg_relationship_years',     updated_at=now() where number = 436;

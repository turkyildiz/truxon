-- R9 #38: seasonality-aware budget seeding. The auto-seed stays a trailing
-- 3-month average, now scaled by a month-of-year factor learned from the GL
-- revenue mirror: avg(same calendar month, PRIOR years) ÷ avg(all history),
-- clamped to [0.75, 1.25]. With only 2026 on the books the factor is exactly
-- 1.0 (no prior-year sample) — today's behavior — and it self-activates the
-- first time a month recurs (January 2027). No fake seasonality from thin
-- data. Reproduced WHOLE from 20260720580001.
create or replace function public.ensure_auto_budget(p_month date default date_trunc('month', now())::date)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line text;
  v_avg numeric;
  v_added int := 0;
  m1 date := p_month - interval '3 months';
  pnl3 jsonb;
  v_factor numeric := 1.0;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  -- trailing 3 FULL months of actuals, one pnl call
  pnl3 := public.pnl_summary(m1::timestamptz, p_month::timestamptz);

  -- month-of-year factor from prior-year GL income months (null until one
  -- exists). NB: GREATEST/LEAST *skip* nulls, so guard the null ratio
  -- explicitly or an empty mirror silently clamps to 0.75.
  select case when f.mavg is null or coalesce(f.oavg, 0) = 0 then null
              else least(greatest(f.mavg / f.oavg, 0.75), 1.25) end into v_factor
    from (select avg(msum) filter (where extract(month from mo) = extract(month from p_month)
                                     and mo < date_trunc('year', p_month)::date) mavg,
                 avg(msum) oavg
            from (select month as mo, sum(amount) as msum
                    from gl_monthly where grp = 'income' group by month) g) f;
  v_factor := coalesce(v_factor, 1.0);

  for v_line, v_avg in
    select * from (values
      ('revenue',     round((pnl3->>'revenue')::numeric / 3, 2)),
      ('fuel',        round((pnl3->>'fuel_cost')::numeric / 3, 2)),
      ('tolls',       round((pnl3->>'toll_cost')::numeric / 3, 2)),
      ('driver_pay',  round((pnl3->>'driver_pay')::numeric / 3, 2)),
      ('maintenance', round((pnl3->>'maintenance_cost')::numeric / 3, 2)),
      ('truck_fixed', round((pnl3->>'truck_fixed_cost')::numeric / 3, 2)),
      ('total_cost',  round((pnl3->>'total_cost')::numeric / 3, 2))
    ) t(line, avg_amt)
  loop
    if v_avg is not null and v_avg <> 0 then
      -- volume lines breathe with the season; fixed costs don't
      if v_line in ('revenue', 'fuel', 'tolls', 'driver_pay', 'total_cost') then
        v_avg := round(v_avg * v_factor, 2);
      end if;
      -- heal: a data source that came online mid-quarter leaves a stale $0
      -- auto line; re-seed it once real actuals produce a nonzero average
      insert into budgets (period_month, line, amount, basis)
      values (p_month, v_line, v_avg, 'auto')
      on conflict (period_month, line) do update
        set amount = excluded.amount
      where budgets.basis = 'auto' and budgets.amount = 0;
      if found then v_added := v_added + 1; end if;
    end if;
  end loop;
  return v_added;
end;
$$;
revoke all on function public.ensure_auto_budget(date) from public, anon;
grant execute on function public.ensure_auto_budget(date) to authenticated, service_role;

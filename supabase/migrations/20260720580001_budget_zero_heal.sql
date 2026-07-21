-- Exam finding (Q19): July's auto-budget carried fuel = $0 because the
-- trailing-3-month seed window predates the fuel backfill (AtoB data starts
-- 2026-07-01). ensure_auto_budget now HEALS auto-basis rows still at 0 when
-- the recomputed trailing average turns positive. Manual rows and nonzero
-- auto rows are never touched. Reproduced WHOLE from 20260720510001.
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
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  -- trailing 3 FULL months of actuals, one pnl call
  pnl3 := public.pnl_summary(m1::timestamptz, p_month::timestamptz);

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

-- heal the current month on prod right now
select public.ensure_auto_budget();

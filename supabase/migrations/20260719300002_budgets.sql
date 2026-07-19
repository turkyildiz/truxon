-- Budgets & variance — the next instrumented data source. Store a monthly
-- budget per P&L line; budget_variance compares it to actuals (from the same
-- computations as pnl_summary) so Trux can answer "are we on budget, and where
-- are we bleeding?" This flips the playbook's budget-vs-actual metrics to live.

create table if not exists public.budgets (
  id bigint generated always as identity primary key,
  period_month date not null,               -- first day of the month
  line text not null check (line in ('revenue','fuel','tolls','driver_pay','maintenance','truck_fixed','total_cost')),
  amount numeric(14,2) not null default 0,
  updated_at timestamptz not null default now(),
  unique (period_month, line)
);
alter table public.budgets enable row level security;
drop policy if exists budgets_read on public.budgets;
create policy budgets_read on public.budgets for select to authenticated
  using (public.my_role() in ('admin','accountant','dispatcher'));
drop policy if exists budgets_write on public.budgets;
create policy budgets_write on public.budgets for all to authenticated
  using (public.my_role() in ('admin','accountant')) with check (public.my_role() in ('admin','accountant'));

-- Budget vs actual per P&L line over a window. Budget = sum of monthly budget
-- rows whose month falls in [start, end); actuals come from pnl_summary so the
-- definitions never drift between the two.
create or replace function public.budget_variance(p_start timestamptz, p_end timestamptz)
returns table (line text, budget numeric, actual numeric, variance numeric, variance_pct numeric)
language plpgsql stable security definer set search_path = public
as $$
declare pnl jsonb;
begin
  if public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  pnl := public.pnl_summary(p_start, p_end);
  return query
  with actuals(line, actual) as (
    values
      ('revenue', (pnl->>'revenue')::numeric),
      ('fuel', (pnl->>'fuel_cost')::numeric),
      ('tolls', (pnl->>'toll_cost')::numeric),
      ('driver_pay', (pnl->>'driver_pay')::numeric),
      ('maintenance', (pnl->>'maintenance_cost')::numeric),
      ('truck_fixed', (pnl->>'truck_fixed_cost')::numeric),
      ('total_cost', (pnl->>'total_cost')::numeric)
  ),
  budg as (
    select b.line, sum(b.amount) amt from public.budgets b
     where b.period_month >= date_trunc('month', p_start)::date
       and b.period_month < p_end::date
     group by b.line
  )
  select a.line, coalesce(bu.amt,0), a.actual,
         round(a.actual - coalesce(bu.amt,0), 2),
         case when coalesce(bu.amt,0) <> 0 then round((a.actual - bu.amt)/bu.amt*100, 1) end
    from actuals a left join budg bu on bu.line = a.line
   order by case a.line when 'revenue' then 0 when 'total_cost' then 9 else 5 end, a.line;
end;
$$;

revoke execute on function public.budget_variance(timestamptz, timestamptz) from public, anon;
grant execute on function public.budget_variance(timestamptz, timestamptz) to authenticated;

-- Flip ONLY the P&L-line budget-vs-actual metrics that budget_variance
-- actually computes (revenue and the cost lines / operating ratio). The many
-- per-drill "(Variance to Budget)" metrics (dwell hours, workers-comp mod,
-- dry-van rev/tractor, etc.) need their own budgets and stay needs_data — we
-- do not mark a metric live that we can't truly compute.
update public.playbook_metrics
   set status = 'live', source = 'budget_variance(start,end)', updated_at = now()
 where status = 'needs_data'
   and name ilike 'Budget vs Actual%'
   and name not ilike '%days red%' and name not ilike '%peer benchmark%' and name not ilike '%variance to budget%'
   and (name ilike '%revenue%' or name ilike '%operating ratio%' or name ilike '% OR %' or name ilike '%OR Variance%'
        or name ilike '%cost%' or name ilike '%fuel%' or name ilike '%driver pay%' or name ilike '%maintenance%' or name ilike '%toll%');

-- GL mirror — the full expense picture, monthly, from the books. Fed by the
-- qbo-sync nightly P&L pull today; in the QuickBooks-free future the same
-- table is where Truxon-native expense entries land.
--
--   gl_monthly            month × account × group amounts (income/cogs/expense)
--   bs_snapshot           balance-sheet point-in-time (cash, AR, AP, ratios' inputs)
--   gl_pnl_monthly()      true P&L: gross/net margin, TRUE operating ratio
--   gl_expense_breakdown() every account, % of revenue — where the money goes
--   gl_breakeven_monthly() actual RPM vs break-even RPM from ALL costs + miles
--   gl_cfo_snapshot()     cash, current ratio, working capital, DPO, interest
--                         coverage, overhead/tractor, total cost of risk
-- Flips 11 Owner's-Playbook metrics from needs_data → live.

create table public.gl_monthly (
  id bigint generated always as identity primary key,
  month date not null,                -- first of month
  account text not null,
  grp text not null check (grp in ('income', 'cogs', 'expense', 'other_income', 'other_expense')),
  amount numeric not null,
  source text not null default 'qbo',
  updated_at timestamptz not null default now(),
  unique (month, account, grp)
);
alter table public.gl_monthly enable row level security;
-- no policies: service writes, admin reads via the RPCs below

create table public.bs_snapshot (
  as_of date primary key,
  cash numeric,
  ar numeric,
  ap numeric,
  current_assets numeric,
  current_liabilities numeric,
  total_assets numeric,
  total_liabilities numeric,
  equity numeric,
  updated_at timestamptz not null default now()
);
alter table public.bs_snapshot enable row level security;

alter table public.qbo_sync_state add column last_pnl_at timestamptz;

-- ── service-side upserts (called by qbo-sync) ───────────────────────────────
-- Replace-by-month semantics: each payload month is authoritative.
create or replace function public.gl_upsert_monthly(p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  delete from gl_monthly where month in (
    select distinct (r->>'month')::date from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
  );
  insert into gl_monthly (month, account, grp, amount)
  select (r->>'month')::date, r->>'account', r->>'grp', (r->>'amount')::numeric
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
  where (r->>'amount')::numeric <> 0
  on conflict (month, account, grp) do update
    set amount = excluded.amount, updated_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.gl_upsert_monthly(jsonb) from public, anon, authenticated;

create or replace function public.bs_upsert(p jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  insert into bs_snapshot (as_of, cash, ar, ap, current_assets, current_liabilities, total_assets, total_liabilities, equity)
  values (
    coalesce((p->>'as_of')::date, current_date),
    (p->>'cash')::numeric, (p->>'ar')::numeric, (p->>'ap')::numeric,
    (p->>'current_assets')::numeric, (p->>'current_liabilities')::numeric,
    (p->>'total_assets')::numeric, (p->>'total_liabilities')::numeric, (p->>'equity')::numeric
  )
  on conflict (as_of) do update set
    cash = excluded.cash, ar = excluded.ar, ap = excluded.ap,
    current_assets = excluded.current_assets, current_liabilities = excluded.current_liabilities,
    total_assets = excluded.total_assets, total_liabilities = excluded.total_liabilities,
    equity = excluded.equity, updated_at = now();
end;
$$;
revoke all on function public.bs_upsert(jsonb) from public, anon, authenticated;

-- ── true P&L by month ───────────────────────────────────────────────────────
create or replace function public.gl_pnl_monthly(p_months int default 12)
returns table (
  month text,
  income numeric,
  cogs numeric,
  gross_profit numeric,
  gross_margin_pct numeric,
  opex numeric,
  other_net numeric,
  net_income numeric,
  net_margin_pct numeric,
  operating_ratio numeric
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return query
  with m as (
    select g.month as mo,
      sum(g.amount) filter (where g.grp = 'income') as inc,
      sum(g.amount) filter (where g.grp = 'cogs') as cg,
      sum(g.amount) filter (where g.grp = 'expense') as ox,
      coalesce(sum(g.amount) filter (where g.grp = 'other_income'), 0)
        - coalesce(sum(g.amount) filter (where g.grp = 'other_expense'), 0) as oth
    from gl_monthly g
    where g.month >= date_trunc('month', now()) - (interval '1 month' * (least(greatest(p_months, 1), 36) - 1))
    group by g.month
  )
  select
    to_char(mo, 'YYYY-MM'),
    coalesce(inc, 0), coalesce(cg, 0),
    coalesce(inc, 0) - coalesce(cg, 0),
    case when coalesce(inc, 0) > 0 then round((inc - coalesce(cg, 0)) / inc * 100, 1) end,
    coalesce(ox, 0), coalesce(oth, 0),
    coalesce(inc, 0) - coalesce(cg, 0) - coalesce(ox, 0) + coalesce(oth, 0),
    case when coalesce(inc, 0) > 0 then round((inc - coalesce(cg, 0) - coalesce(ox, 0) + coalesce(oth, 0)) / inc * 100, 1) end,
    case when coalesce(inc, 0) > 0 then round((coalesce(cg, 0) + coalesce(ox, 0)) / inc * 100, 1) end
  from m
  order by 1;
end;
$$;
revoke all on function public.gl_pnl_monthly(int) from public, anon;

-- ── where the money goes ────────────────────────────────────────────────────
create or replace function public.gl_expense_breakdown(p_months int default 6)
returns table (
  account text,
  grp text,
  total numeric,
  monthly_avg numeric,
  pct_of_revenue numeric
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_rev numeric;
  v_start date := date_trunc('month', now()) - (interval '1 month' * (least(greatest(p_months, 1), 36) - 1));
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(sum(g.amount), 0) into v_rev from gl_monthly g where g.grp = 'income' and g.month >= v_start;
  return query
  select g.account, g.grp, sum(g.amount),
    round(sum(g.amount) / greatest(count(distinct g.month), 1), 2),
    case when v_rev > 0 then round(sum(g.amount) / v_rev * 100, 2) end
  from gl_monthly g
  where g.grp in ('cogs', 'expense', 'other_expense') and g.month >= v_start
  group by g.account, g.grp
  order by 3 desc;
end;
$$;
revoke all on function public.gl_expense_breakdown(int) from public, anon;

-- ── break-even rate per mile (ALL costs ÷ miles run) ────────────────────────
create or replace function public.gl_breakeven_monthly(p_months int default 12)
returns table (
  month text,
  revenue numeric,
  total_costs numeric,
  miles numeric,
  rpm_actual numeric,
  rpm_breakeven numeric,
  cushion_pct numeric
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return query
  with gl as (
    select g.month as mo,
      coalesce(sum(g.amount) filter (where g.grp = 'income'), 0) as inc,
      coalesce(sum(g.amount) filter (where g.grp in ('cogs', 'expense', 'other_expense')), 0) as costs
    from gl_monthly g
    where g.month >= date_trunc('month', now()) - (interval '1 month' * (least(greatest(p_months, 1), 36) - 1))
    group by g.month
  ),
  mi as (
    select date_trunc('month', delivery_time)::date as mo, sum(l.miles + coalesce(l.empty_miles, 0)) as miles
    from loads l
    where l.status in ('delivered', 'completed', 'billed') and l.delivery_time is not null
    group by 1
  )
  select
    to_char(gl.mo, 'YYYY-MM'),
    gl.inc, gl.costs,
    coalesce(mi.miles, 0),
    case when coalesce(mi.miles, 0) > 0 then round(gl.inc / mi.miles, 3) end,
    case when coalesce(mi.miles, 0) > 0 then round(gl.costs / mi.miles, 3) end,
    case when gl.costs > 0 then round((gl.inc - gl.costs) / gl.costs * 100, 1) end
  from gl left join mi on mi.mo = gl.mo
  order by 1;
end;
$$;
revoke all on function public.gl_breakeven_monthly(int) from public, anon;

-- ── CFO snapshot ────────────────────────────────────────────────────────────
create or replace function public.gl_cfo_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  bs bs_snapshot;
  v_rev12 numeric;
  v_costs12 numeric;
  v_noi12 numeric;
  v_interest12 numeric;
  v_risk12 numeric;
  v_trucks int;
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  select * into bs from bs_snapshot order by as_of desc limit 1;
  select
    coalesce(sum(amount) filter (where grp = 'income'), 0),
    coalesce(sum(amount) filter (where grp in ('cogs', 'expense', 'other_expense')), 0),
    coalesce(sum(amount) filter (where grp = 'income'), 0)
      - coalesce(sum(amount) filter (where grp in ('cogs', 'expense')), 0),
    coalesce(sum(amount) filter (where account ~* 'interest'), 0),
    coalesce(sum(amount) filter (where account ~* 'insurance|physical damage|penalt|settlement|claim'), 0)
  into v_rev12, v_costs12, v_noi12, v_interest12, v_risk12
  from gl_monthly where month >= date_trunc('month', now()) - interval '11 months';
  select count(*) into v_trucks from trucks where status <> 'retired';

  return jsonb_build_object(
    'as_of', bs.as_of,
    'cash', bs.cash,
    'ap', bs.ap,
    'working_capital', case when bs.current_assets is not null and bs.current_liabilities is not null
                         then bs.current_assets - bs.current_liabilities end,
    'working_capital_pct_revenue', case when v_rev12 > 0 and bs.current_assets is not null and bs.current_liabilities is not null
                                     then round((bs.current_assets - bs.current_liabilities) / v_rev12 * 100, 1) end,
    'current_ratio', case when coalesce(bs.current_liabilities, 0) > 0
                       then round(bs.current_assets / bs.current_liabilities, 2) end,
    'dpo', case when v_costs12 > 0 and bs.ap is not null then round(bs.ap / v_costs12 * 365, 1) end,
    'days_of_cash', case when v_costs12 > 0 and bs.cash is not null then round(bs.cash / (v_costs12 / 365), 1) end,
    'interest_coverage', case when v_interest12 > 0 then round(v_noi12 / v_interest12, 1) end,
    'overhead_per_tractor_month', case when v_trucks > 0 then round(
      (select coalesce(sum(amount), 0) from gl_monthly where grp = 'expense' and month >= date_trunc('month', now()) - interval '11 months')
      / v_trucks / 12, 0) end,
    'total_cost_of_risk_12m', v_risk12,
    'revenue_12m', v_rev12
  );
end;
$$;
revoke all on function public.gl_cfo_snapshot() from public, anon;

-- ── playbook flips: metrics now truly computable from the GL mirror ─────────
update public.playbook_metrics set
  status = 'live',
  source = 'gl_monthly / bs_snapshot (QBO GL mirror): gl_pnl_monthly, gl_breakeven_monthly, gl_expense_breakdown, gl_cfo_snapshot'
where number in (24, 25, 36, 37, 38, 45, 47, 48, 50, 54, 86)
  and status = 'needs_data';

-- Trend infrastructure: the playbook registry holds ~50 derivative metrics
-- (WoW change, 13-week trend slope) that were gated on having a TIME SERIES.
-- This lays the series down: every night we flatten the numeric leaves of the
-- already-tested scorecard RPCs into metric_snapshots, and metric_trends()
-- reads WoW / MoM deltas + a 13-week slope off the accumulated history. New
-- scorecard sections start accumulating history automatically — no per-metric
-- plumbing. Flips only the derivative metrics whose BASE number is live today.

create table if not exists public.metric_snapshots (
  metric_key text not null,
  captured_on date not null default current_date,
  value numeric not null,
  primary key (metric_key, captured_on)
);
alter table public.metric_snapshots enable row level security;
grant select on public.metric_snapshots to authenticated;
drop policy if exists metric_snapshots_read on public.metric_snapshots;
create policy metric_snapshots_read on public.metric_snapshots
  for select using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

-- ── recursive flatten: jsonb object tree → (dotted.path, numeric) rows ──
create or replace function public.metric_flatten(p_prefix text, p_json jsonb)
returns table (metric_key text, value numeric)
language plpgsql
immutable
as $$
declare r record;
begin
  if p_json is null then
    return;
  elsif jsonb_typeof(p_json) = 'object' then
    for r in select * from jsonb_each(p_json) as je(kk, vv) loop
      return query select * from public.metric_flatten(p_prefix || '.' || r.kk, r.vv);
    end loop;
  elsif jsonb_typeof(p_json) = 'number' then
    return query select p_prefix, (p_json #>> '{}')::numeric;
  end if;
  -- strings / booleans / arrays / nulls are not trendable scalars — skipped
end;
$$;

-- ── nightly capture (cron runs as postgres; admins may trigger manually) ──
create or replace function public.capture_metric_snapshots()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_count int := 0;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  insert into metric_snapshots (metric_key, captured_on, value)
  select mf.metric_key, current_date, mf.value
  from (
    select * from public.metric_flatten('scorecard7',
      public.company_scorecard(now() - interval '7 days', now()))
    union all
    select * from public.metric_flatten('scorecard30',
      public.company_scorecard(now() - interval '30 days', now()))
    union all
    select * from public.metric_flatten('ops7',
      public.fleet_ops_extras(now() - interval '7 days', now()))
    union all
    select * from public.metric_flatten('costbasis', public.fleet_cost_basis())
    union all
    select * from public.metric_flatten('cfo', public.gl_cfo_snapshot())
    union all
    -- AR risk buckets from open invoices (real outstanding, mirror-aware)
    select 'ar.over_45', coalesce(sum(
             case when i.source = 'qbo' then coalesce(i.qbo_balance, 0)
                  else i.total - coalesce(p.paid, 0) end), 0)
    from invoices i
    left join lateral (
      select sum(ip.amount) paid from invoice_payments ip where ip.invoice_id = i.id
    ) p on true
    where i.status = 'sent' and i.invoice_date < now() - interval '45 days'
  ) mf
  where mf.value is not null and abs(mf.value) < 1e13
  on conflict (metric_key, captured_on) do update set value = excluded.value;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.capture_metric_snapshots() from public, anon, authenticated;
grant execute on function public.capture_metric_snapshots() to service_role;

-- ── trends off the series: latest, WoW, MoM, 13-week slope ──
create or replace function public.metric_trends(p_prefix text default null)
returns table (
  metric_key text,
  latest numeric,
  latest_on date,
  wow numeric,
  wow_pct numeric,
  mom numeric,
  mom_pct numeric,
  slope_13w numeric,
  points int
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return query
  with latest as (
    select distinct on (ms.metric_key) ms.metric_key k, ms.value v, ms.captured_on d
    from metric_snapshots ms
    where p_prefix is null or ms.metric_key like p_prefix || '%'
    order by ms.metric_key, ms.captured_on desc
  ),
  prior_w as (   -- nearest snapshot 4-10 days back (tolerates missed nights)
    select distinct on (ms.metric_key) ms.metric_key k, ms.value v
    from metric_snapshots ms join latest l on l.k = ms.metric_key
    where ms.captured_on between l.d - 10 and l.d - 4
    order by ms.metric_key, abs(ms.captured_on - (l.d - 7))
  ),
  prior_m as (   -- nearest snapshot 21-42 days back
    select distinct on (ms.metric_key) ms.metric_key k, ms.value v
    from metric_snapshots ms join latest l on l.k = ms.metric_key
    where ms.captured_on between l.d - 42 and l.d - 21
    order by ms.metric_key, abs(ms.captured_on - (l.d - 28))
  ),
  slope as (     -- per-day linear slope over the trailing 91 days
    select ms.metric_key k,
           regr_slope(ms.value::float8, (ms.captured_on - current_date)::float8) s,
           count(*)::int n
    from metric_snapshots ms
    where ms.captured_on > current_date - 91
      and (p_prefix is null or ms.metric_key like p_prefix || '%')
    group by ms.metric_key
  )
  select l.k, l.v, l.d,
         l.v - pw.v,
         case when pw.v is not null and pw.v <> 0 then round((l.v - pw.v) / abs(pw.v) * 100, 2) end,
         l.v - pm.v,
         case when pm.v is not null and pm.v <> 0 then round((l.v - pm.v) / abs(pm.v) * 100, 2) end,
         round(sl.s::numeric, 6), sl.n
  from latest l
  left join prior_w pw on pw.k = l.k
  left join prior_m pm on pm.k = l.k
  left join slope sl on sl.k = l.k
  order by l.k;
end;
$$;
revoke all on function public.metric_trends(text) from public, anon;
grant execute on function public.metric_trends(text) to authenticated, service_role;

-- ── nightly cron (pure SQL — runs as postgres, no edge function needed) ──
do $$ begin perform cron.unschedule('truxon-metric-snapshot'); exception when others then null; end $$;
select cron.schedule('truxon-metric-snapshot', '41 2 * * *',
  $$select public.capture_metric_snapshots()$$);

-- seed today's snapshot so the series starts NOW, not tomorrow night
select public.capture_metric_snapshots();

-- ── flip the derivative metrics whose base number is live today ──
update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'metric_snapshots + metric_trends() — nightly series over live scorecard values'
where number in (
  108,  -- WoW Change in Free Cash Flow (net cash flow from scorecard financials)
  110,  -- Trailing 4-Week Cash Balance trend (cfo.cash series)
  128,  -- WoW Change in Fuel CPM (costbasis fuel series)
  142,  -- AR > 45 Days $ — 13-week trend slope (ar.over_45 series)
  299,  -- Miles per Driver per Week — 13-week trend slope (ops7 series)
  451   -- WoW Change in Avg Rate / Loaded Mile (costbasis.avg_rpm series)
) and status <> 'live';

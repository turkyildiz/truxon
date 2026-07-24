-- R9 #165: real-user timing. The web app reports its own field performance —
-- TTFB/FCP/LCP per page plus session length — into a small table; the report
-- answers "is the app actually fast for the person using it" with percentiles
-- from real sessions, not lab numbers. Best-effort by design (a killed tab
-- may not flush); no IP, no UA string — just timings, path and user.
create table if not exists public.web_vitals (
  id bigserial primary key,
  session_id text not null,
  user_id uuid default auth.uid(),
  path text not null default '',
  metric text not null check (metric in ('ttfb','fcp','lcp','route','session_s')),
  value numeric not null check (value >= 0),
  created_at timestamptz not null default now()
);
create index if not exists web_vitals_created_idx on public.web_vitals (created_at desc);

alter table public.web_vitals enable row level security;
revoke all on table public.web_vitals from anon, authenticated;
grant insert, select on public.web_vitals to authenticated;
drop policy if exists wv_insert on public.web_vitals;
create policy wv_insert on public.web_vitals
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists wv_select on public.web_vitals;
create policy wv_select on public.web_vitals
  for select to authenticated using (public.my_role() = 'admin');
insert into app_private.security_baseline (kind, item) values
  ('grant', 'authenticated web_vitals INSERT'),
  ('grant', 'authenticated web_vitals SELECT')
on conflict do nothing;

create or replace function public.web_perf_report(p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() = 'admin') then
    raise exception 'Not enough permissions';
  end if;
  with w as (
    select * from web_vitals where created_at > now() - make_interval(days => p_days)
  )
  select jsonb_build_object(
    'days', p_days,
    'sessions', (select count(distinct session_id) from w),
    'metrics', coalesce((select jsonb_object_agg(m.metric, jsonb_build_object(
        'n', m.n, 'p50', m.p50, 'p95', m.p95))
      from (select metric, count(*) n,
                   round((percentile_cont(0.5) within group (order by value))::numeric, 0) p50,
                   round((percentile_cont(0.95) within group (order by value))::numeric, 0) p95
              from w where metric <> 'session_s' group by metric) m), '{}'::jsonb),
    'avg_session_min', (select round(avg(value) / 60.0, 1) from w where metric = 'session_s'),
    'slowest_pages', coalesce((select jsonb_agg(jsonb_build_object(
        'path', s.path, 'n', s.n, 'lcp_p75', s.p75) order by s.p75 desc)
      from (select path, count(*) n,
                   round((percentile_cont(0.75) within group (order by value))::numeric, 0) p75
              from w where metric = 'lcp' group by path
            having count(*) >= 3 order by p75 desc limit 6) s), '[]'::jsonb),
    'note', 'real-user timings (ms), best-effort beacon — killed tabs may not report; no IP or UA stored',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.web_perf_report(int) from public, anon, authenticated;
grant execute on function public.web_perf_report(int) to authenticated, service_role;

-- keep the shelf small: samples expire after 90 days
select cron.schedule('truxon-web-vitals-purge', '40 5 * * *',
  $$ delete from public.web_vitals where created_at < now() - interval '90 days' $$);

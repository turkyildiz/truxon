-- R9 #3/4/7: extraction ledger. Every live LLM extraction (local NAS 3B,
-- Lynx heavy, cloud fallback, vision) is banked with model/arm/latency/output,
-- so office corrections become labels automatically and model A/Bs score
-- themselves on real traffic instead of vibes. Prompt text is NOT stored —
-- sha + length only (bodies may contain customer data); output fields are
-- what we already write into the app anyway.
create table if not exists public.llm_extractions (
  id bigserial primary key,
  kind text not null default 'unknown',          -- wo | quote | classify | enrich | vision | unknown
  ref text,                                      -- doc id / message id the caller was working
  model text not null,
  arm text not null check (arm in ('local','cloud','vision')),
  ok boolean not null default true,              -- parseable output produced
  latency_ms int,
  prompt_sha text,
  prompt_len int,
  output jsonb,
  created_at timestamptz not null default now()
);
create index if not exists llm_extractions_created_idx on public.llm_extractions (created_at desc);
create index if not exists llm_extractions_kind_idx on public.llm_extractions (kind, arm);
alter table public.llm_extractions enable row level security;
-- Supabase default privileges hand anon/authenticated ALL (incl. TRUNCATE) on
-- new public tables — the posture-drift tripwire caught exactly that. Strip to
-- the one intended grant and bless it.
revoke all on public.llm_extractions from anon, authenticated;
grant select on public.llm_extractions to authenticated;
drop policy if exists llm_extractions_admin_read on public.llm_extractions;
create policy llm_extractions_admin_read on public.llm_extractions
  for select to authenticated using (public.my_role() = 'admin');
insert into app_private.security_baseline (kind, item)
values ('grant', 'authenticated llm_extractions SELECT')
on conflict do nothing;

-- Rollup for the observability card / weekly digest.
create or replace function public.llm_eval_summary(p_days int default 7)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(row order by (row->>'n')::int desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'kind', kind, 'arm', arm, 'model', model,
      'n', count(*),
      'ok_pct', round(100.0 * count(*) filter (where ok) / count(*), 1),
      'p50_ms', percentile_disc(0.5) within group (order by latency_ms),
      'p95_ms', percentile_disc(0.95) within group (order by latency_ms)
    ) as row
    from llm_extractions
    where created_at > now() - make_interval(days => p_days)
    group by kind, arm, model
  ) x;
$$;
revoke all on function public.llm_eval_summary(int) from public, anon;
grant execute on function public.llm_eval_summary(int) to authenticated, service_role;

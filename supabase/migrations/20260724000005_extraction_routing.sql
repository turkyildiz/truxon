-- R9 #3/#4: extraction A/B harness + winner routing. The llm_extractions
-- ledger already tracks latency/ok, but not ACCURACY against a human-verified
-- answer. This adds the accuracy layer: the owner's A/B runner scores each
-- engine (lynx-7b / nas-3b / cloud) on the 50 verified docs and writes rows
-- here; the ranking aggregates them, and apply_extraction_routing() promotes
-- the measured winner per doc type into a routing table that classify/extract
-- consult via best_extraction_engine(). Ships with a safe default so routing
-- works before any measurement lands, and only overrides on real evidence.
create table if not exists public.extraction_ab_scores (
  id bigserial primary key,
  doc_type text not null,
  engine text not null check (engine in ('lynx-7b','nas-3b','cloud')),
  doc_ref text,                                  -- document id / label the score is for
  field_accuracy numeric(5,2) not null check (field_accuracy between 0 and 100),
  latency_ms int,
  cost_cents numeric(8,3) not null default 0,
  ran_at timestamptz not null default now()
);
create index if not exists extraction_ab_scores_idx on public.extraction_ab_scores (doc_type, engine, ran_at desc);
alter table public.extraction_ab_scores enable row level security;
revoke all on table public.extraction_ab_scores from anon, authenticated;
grant select on public.extraction_ab_scores to authenticated;
drop policy if exists eabs_read on public.extraction_ab_scores;
create policy eabs_read on public.extraction_ab_scores
  for select to authenticated using (public.my_role() = 'admin');
insert into app_private.security_baseline (kind, item)
values ('grant', 'authenticated extraction_ab_scores SELECT') on conflict do nothing;

create table if not exists public.extraction_routing (
  doc_type text primary key,
  engine text not null check (engine in ('lynx-7b','nas-3b','cloud')),
  reason text not null default '',
  auto boolean not null default true,            -- false = a human pinned it
  updated_at timestamptz not null default now()
);
alter table public.extraction_routing enable row level security;
revoke all on table public.extraction_routing from anon, authenticated;
grant select on public.extraction_routing to authenticated;
drop policy if exists er_read on public.extraction_routing;
create policy er_read on public.extraction_routing
  for select to authenticated using (public.my_role() in ('admin','accountant','dispatcher'));
insert into app_private.security_baseline (kind, item)
values ('grant', 'authenticated extraction_routing SELECT') on conflict do nothing;

-- The resolver classify/extract consult. Default reflects the measured house
-- finding (the NAS 3B beat the 7B on extraction) until a doc-type-specific
-- winner is recorded.
create or replace function public.best_extraction_engine(p_doc_type text)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select engine from extraction_routing where doc_type = p_doc_type),
    'nas-3b');
$$;
revoke all on function public.best_extraction_engine(text) from public, anon;
grant execute on function public.best_extraction_engine(text) to authenticated, service_role;

-- Per-(doc_type,engine) rollup with a composite score: accuracy is king, with
-- a small latency tie-breaker (1 pt per full second) and cost tie-breaker
-- (1 pt per 10c). Marks the winning engine per doc type.
create or replace function public.extraction_engine_ranking(p_days int default 120, p_min_samples int default 3)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() = 'admin') then
    raise exception 'Not enough permissions';
  end if;
  with agg as (
    select doc_type, engine, count(*) n,
           round(avg(field_accuracy), 1) as accuracy,
           round(avg(latency_ms)) as latency_ms,
           round(avg(cost_cents), 2) as cost_cents,
           round(avg(field_accuracy) - avg(latency_ms) / 1000.0 - avg(cost_cents) / 10.0, 2) as composite
      from extraction_ab_scores
     where ran_at > now() - make_interval(days => p_days)
     group by doc_type, engine
    having count(*) >= p_min_samples
  ), ranked as (
    select *, row_number() over (partition by doc_type order by composite desc) as rk from agg
  )
  select jsonb_build_object(
    'days', p_days, 'min_samples', p_min_samples,
    'by_doc_type', coalesce((select jsonb_object_agg(doc_type, engines) from (
        select doc_type, jsonb_agg(jsonb_build_object(
            'engine', engine, 'n', n, 'accuracy', accuracy, 'latency_ms', latency_ms,
            'cost_cents', cost_cents, 'composite', composite, 'winner', rk = 1)
            order by composite desc) as engines
          from ranked group by doc_type) d), '{}'::jsonb),
    'note', 'composite = avg field accuracy − 1pt/sec latency − 1pt/10c cost; winner is the top composite with enough samples',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.extraction_engine_ranking(int, int) from public, anon, authenticated;
grant execute on function public.extraction_engine_ranking(int, int) to authenticated, service_role;

-- #4: promote each measured winner into the routing table (auto rows only;
-- never clobbers a human-pinned route). Returns how many routes changed.
create or replace function public.apply_extraction_routing(p_days int default 120, p_min_samples int default 3)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare changed int := 0; r record;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() = 'admin') then
    raise exception 'Not enough permissions';
  end if;
  for r in
    with agg as (
      select doc_type, engine,
             avg(field_accuracy) - avg(latency_ms) / 1000.0 - avg(cost_cents) / 10.0 as composite
        from extraction_ab_scores
       where ran_at > now() - make_interval(days => p_days)
       group by doc_type, engine
      having count(*) >= p_min_samples
    ), win as (
      select distinct on (doc_type) doc_type, engine, composite
        from agg order by doc_type, composite desc
    )
    select * from win
  loop
    insert into extraction_routing (doc_type, engine, reason, auto, updated_at)
    values (r.doc_type, r.engine, 'auto: highest composite over '||p_days||'d', true, now())
    on conflict (doc_type) do update
      set engine = excluded.engine, reason = excluded.reason, updated_at = now()
      where extraction_routing.auto and extraction_routing.engine <> excluded.engine;
    if found then changed := changed + 1; end if;
  end loop;
  return jsonb_build_object('routes_changed', changed, 'as_of', now());
end;
$$;
revoke all on function public.apply_extraction_routing(int, int) from public, anon, authenticated;
grant execute on function public.apply_extraction_routing(int, int) to authenticated, service_role;

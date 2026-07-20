-- Trux dispatch shadow (owner 2026-07-20): Trux watches dispatch@aidalogistics.com
-- and records what it WOULD do — never executes, never sends. Boss reviews the
-- ledger for ~2 months, then decides what to promote to real action.
--
--   trux_observations       one row per email Trux processed (exactly-once by
--                           message_id); carries its read + the action it would take
--   log_observation()       service-side insert from the shadow poller (idempotent)

create table if not exists public.trux_observations (
  id bigint generated always as identity primary key,
  message_id text not null unique,          -- Graph message id → exactly-once
  received_at timestamptz,
  sender_email text not null default '',
  sender_name text not null default '',
  subject text not null default '',
  -- Trux's read of the email
  classification text not null default 'other'
    check (classification in ('rate_con','pod','bol','detention','lumper','tonu',
                              'quote','load_offer','payment','check_call','claim','other')),
  summary text not null default '',         -- one-line human read
  extracted jsonb,                          -- structured fields (rate con → customer/stops/rate, …)
  -- the action Trux WOULD take (shadow — not executed)
  would_action text not null default 'none'
    check (would_action in ('create_load','file_document','flag_accessorial',
                            'enrich_customer','draft_reply','none')),
  would_detail text not null default '',
  confidence text not null default 'medium' check (confidence in ('low','medium','high')),
  -- Trux's best-guess links into real data (for the reviewer; no FK enforcement so
  -- an observation never blocks or is blocked by a load/customer edit)
  matched_customer_id bigint,
  matched_load_id bigint,
  -- reviewer state
  reviewed boolean not null default false,
  review_note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists trux_observations_class_idx on public.trux_observations (classification, created_at desc);
create index if not exists trux_observations_unreviewed_idx on public.trux_observations (created_at desc) where not reviewed;

alter table public.trux_observations enable row level security;
grant select, update on public.trux_observations to authenticated;
-- staff who run dispatch can read + mark reviewed; service writes via the RPC
drop policy if exists trux_obs_read on public.trux_observations;
create policy trux_obs_read on public.trux_observations
  for select using (public.my_role() in ('admin','dispatcher'));
drop policy if exists trux_obs_review on public.trux_observations;
create policy trux_obs_review on public.trux_observations
  for update using (public.my_role() in ('admin','dispatcher'))
  with check (public.my_role() in ('admin','dispatcher'));

-- ── shadow poller writes here (service only; idempotent by message_id) ──
create or replace function public.log_observation(p jsonb)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v_id bigint;
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  insert into trux_observations (
    message_id, received_at, sender_email, sender_name, subject,
    classification, summary, extracted, would_action, would_detail, confidence,
    matched_customer_id, matched_load_id)
  values (
    p->>'message_id', (p->>'received_at')::timestamptz, coalesce(p->>'sender_email',''),
    coalesce(p->>'sender_name',''), coalesce(p->>'subject',''),
    coalesce(p->>'classification','other'), coalesce(p->>'summary',''), p->'extracted',
    coalesce(p->>'would_action','none'), coalesce(p->>'would_detail',''),
    coalesce(p->>'confidence','medium'),
    nullif(p->>'matched_customer_id','')::bigint, nullif(p->>'matched_load_id','')::bigint)
  on conflict (message_id) do nothing
  returning id into v_id;
  return v_id;  -- null when the message was already logged
end;
$$;
revoke all on function public.log_observation(jsonb) from public, anon, authenticated;

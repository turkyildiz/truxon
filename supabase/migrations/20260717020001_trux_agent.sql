-- Trux agent: sessions, proposed actions, spend ledger, companion config.

create table if not exists public.companion_config (
  id int primary key default 1 check (id = 1),
  flags jsonb not null default '{"agent_enabled": true, "voice_enabled": false, "soft_confirm_attach": true}'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.companion_config (id) values (1) on conflict do nothing;

alter table public.companion_config enable row level security;
drop policy if exists companion_config_admin on public.companion_config;
create policy companion_config_admin on public.companion_config
  for all to authenticated
  using (public.my_role() = 'admin')
  with check (public.my_role() = 'admin');

drop policy if exists companion_config_staff_read on public.companion_config;
create policy companion_config_staff_read on public.companion_config
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create table if not exists public.llm_spend_daily (
  day date not null,
  provider text not null,
  cents_spent int not null default 0,
  request_count int not null default 0,
  primary key (day, provider)
);

alter table public.llm_spend_daily enable row level security;
drop policy if exists llm_spend_admin on public.llm_spend_daily;
create policy llm_spend_admin on public.llm_spend_daily
  for select to authenticated
  using (public.my_role() = 'admin');

create table if not exists public.llm_budget (
  id int primary key default 1 check (id = 1),
  monthly_cap_cents int not null default 7500, -- $75
  updated_at timestamptz not null default now()
);
insert into public.llm_budget (id) values (1) on conflict do nothing;

alter table public.llm_budget enable row level security;
drop policy if exists llm_budget_admin on public.llm_budget;
create policy llm_budget_admin on public.llm_budget
  for all to authenticated
  using (public.my_role() = 'admin')
  with check (public.my_role() = 'admin');

create table if not exists public.trux_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  title text not null default 'Trux'
);

create table if not exists public.trux_messages (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.trux_sessions (id) on delete cascade,
  role text not null check (role in ('user', 'assistant', 'system', 'tool')),
  content text not null default '',
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists trux_messages_session_idx on public.trux_messages (session_id, id);

-- proposed → executing → executed | failed
create table if not exists public.trux_actions (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.trux_sessions (id) on delete cascade,
  user_id uuid not null references public.profiles (id),
  tool_name text not null,
  args jsonb not null default '{}'::jsonb,
  status text not null default 'proposed'
    check (status in ('proposed', 'executing', 'executed', 'failed', 'expired')),
  confirmation_token text not null unique,
  result jsonb,
  error text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  executed_at timestamptz
);

create index if not exists trux_actions_session_idx on public.trux_actions (session_id, created_at desc);

alter table public.trux_sessions enable row level security;
alter table public.trux_messages enable row level security;
alter table public.trux_actions enable row level security;

drop policy if exists trux_sessions_own on public.trux_sessions;
create policy trux_sessions_own on public.trux_sessions
  for all to authenticated
  using (user_id = auth.uid() and public.my_role() in ('admin', 'dispatcher'))
  with check (user_id = auth.uid() and public.my_role() in ('admin', 'dispatcher'));

drop policy if exists trux_messages_own on public.trux_messages;
create policy trux_messages_own on public.trux_messages
  for select to authenticated
  using (
    exists (
      select 1 from public.trux_sessions s
       where s.id = session_id and s.user_id = auth.uid()
    )
  );

drop policy if exists trux_messages_insert_own on public.trux_messages;
create policy trux_messages_insert_own on public.trux_messages
  for insert to authenticated
  with check (
    exists (
      select 1 from public.trux_sessions s
       where s.id = session_id and s.user_id = auth.uid()
    )
  );

drop policy if exists trux_actions_own on public.trux_actions;
create policy trux_actions_own on public.trux_actions
  for select to authenticated
  using (user_id = auth.uid());

-- Spend reservation (SECURITY DEFINER)
create or replace function public.llm_reserve_spend(p_provider text, p_cents int)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  cap int;
  spent int;
  d date := current_date;
begin
  if p_cents < 0 then
    raise exception 'bad cents';
  end if;
  select monthly_cap_cents into cap from public.llm_budget where id = 1 for update;
  select coalesce(sum(cents_spent), 0) into spent
    from public.llm_spend_daily
   where day >= date_trunc('month', d)::date;

  if spent + p_cents > cap then
    return false;
  end if;

  insert into public.llm_spend_daily (day, provider, cents_spent, request_count)
  values (d, p_provider, p_cents, 1)
  on conflict (day, provider) do update set
    cents_spent = public.llm_spend_daily.cents_spent + excluded.cents_spent,
    request_count = public.llm_spend_daily.request_count + 1;
  return true;
end;
$$;

revoke all on function public.llm_reserve_spend(text, int) from public, anon, authenticated;
grant execute on function public.llm_reserve_spend(text, int) to service_role;

-- Audit helper for agent tools
create table if not exists public.trux_agent_audit (
  id bigint generated always as identity primary key,
  user_id uuid,
  session_id uuid,
  tool_name text not null,
  args jsonb,
  status text,
  detail text,
  created_at timestamptz not null default now()
);

alter table public.trux_agent_audit enable row level security;
drop policy if exists trux_audit_admin on public.trux_agent_audit;
create policy trux_audit_admin on public.trux_agent_audit
  for select to authenticated
  using (public.my_role() = 'admin');

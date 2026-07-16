-- Lightweight per-user rate limiting for edge functions (e.g. AI PDF extraction).
-- The table is only reachable through the SECURITY DEFINER function below;
-- RLS is on with no policies, so clients cannot read or write it directly.

create table public.rate_limit_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  action text not null,
  created_at timestamptz not null default now()
);

create index rate_limit_lookup_idx on public.rate_limit_events (user_id, action, created_at);

alter table public.rate_limit_events enable row level security;

-- Atomically check the caller's usage of `p_action` in the trailing window and,
-- if under the limit, record this call. Returns true if allowed, false if the
-- limit is already reached. Old rows for the caller/action are pruned opportunistically.
create or replace function public.check_rate_limit(
  p_action text,
  p_max int,
  p_window interval default interval '1 hour'
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  recent int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  delete from public.rate_limit_events
   where user_id = auth.uid() and action = p_action and created_at < now() - p_window;

  select count(*) into recent
    from public.rate_limit_events
   where user_id = auth.uid() and action = p_action and created_at >= now() - p_window;

  if recent >= p_max then
    return false;
  end if;

  insert into public.rate_limit_events (user_id, action) values (auth.uid(), p_action);
  return true;
end;
$$;

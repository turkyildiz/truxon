-- Durable per-IP rate limiting for PUBLIC (unauthenticated) edge endpoints.
-- The existing check_rate_limit keys on auth.uid(); the public quote-request
-- door has no user, so its cooldown lived in an in-memory Map — per-isolate and
-- reset on every cold start, so a burst across isolates slips through (review
-- LOW). This moves it to the database, shared across all isolates.
create table if not exists public.ip_rate_limit_events (
  id bigint generated always as identity primary key,
  ip text not null,
  action text not null,
  created_at timestamptz not null default now()
);
create index if not exists ip_rate_limit_lookup_idx
  on public.ip_rate_limit_events (ip, action, created_at);
alter table public.ip_rate_limit_events enable row level security;  -- reachable only via the definer fn below
-- Strip the default table grants (incl. TRUNCATE, which RLS does not gate) — the
-- table is touched only through check_ip_rate_limit; no client role needs it.
revoke all on table public.ip_rate_limit_events from anon, authenticated;

-- Atomically check this ip's usage of p_action in the trailing window and, if
-- under the limit, record the call. Returns true if allowed. Prunes opportunistically.
create or replace function public.check_ip_rate_limit(
  p_ip text,
  p_action text,
  p_max int,
  p_window interval default interval '1 minute'
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare recent int;
begin
  if coalesce(p_ip, '') = '' then p_ip := 'unknown'; end if;
  delete from public.ip_rate_limit_events
   where action = p_action and created_at < now() - p_window;
  select count(*) into recent
    from public.ip_rate_limit_events
   where ip = p_ip and action = p_action and created_at >= now() - p_window;
  if recent >= p_max then
    return false;
  end if;
  insert into public.ip_rate_limit_events (ip, action) values (p_ip, p_action);
  return true;
end;
$$;
revoke all on function public.check_ip_rate_limit(text, text, int, interval) from public, anon, authenticated;
grant execute on function public.check_ip_rate_limit(text, text, int, interval) to service_role;

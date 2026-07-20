-- Document semantic search — request queue.
-- The query text must be embedded by the SAME local model as the documents
-- (nomic-embed-text); embeddings from different models aren't comparable. Supabase
-- can't reach the NAS (Tailscale), so a user's search is a queued request: the app
-- enqueues it, the NAS worker (already polling) embeds it locally + runs the match,
-- and writes the results back. Free, private, no inbound NAS exposure.
--
--   doc_search_requests     one row per search; results land in `results` jsonb
--   enqueue_doc_search()    app (admin/dispatcher/accountant) → new pending request
--   claim_doc_search()      service (NAS via edge) → grab oldest pending, mark it
--   complete_doc_search()   service → store matches (or an error) and finish

create table if not exists public.doc_search_requests (
  id bigint generated always as identity primary key,
  requester uuid references auth.users (id) on delete set null,
  query text not null,
  entity_type text,
  status text not null default 'pending' check (status in ('pending', 'processing', 'done', 'error')),
  results jsonb,
  error text,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  completed_at timestamptz
);
create index if not exists doc_search_requests_pending_idx on public.doc_search_requests (id) where status = 'pending';
create index if not exists doc_search_requests_requester_idx on public.doc_search_requests (requester);

alter table public.doc_search_requests enable row level security;

-- the requester (or an admin) can read their own request rows to poll for results
drop policy if exists doc_search_own_read on public.doc_search_requests;
create policy doc_search_own_read on public.doc_search_requests
  for select using (requester = auth.uid() or public.my_role() = 'admin');

-- ── enqueue (app) ─────────────────────────────────────────────────────────────
create or replace function public.enqueue_doc_search(
  p_query text,
  p_entity_type text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  if length(v_q) < 2 then
    raise exception 'Query too short';
  end if;
  insert into doc_search_requests (requester, query, entity_type)
  values (auth.uid(), left(v_q, 500), nullif(p_entity_type, ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.enqueue_doc_search(text, text) from public, anon;

-- ── claim (service / NAS worker) ──────────────────────────────────────────────
-- Atomic grab of the oldest pending request. Returns 0 rows when the queue is empty.
create or replace function public.claim_doc_search()
returns table (id bigint, query text, entity_type text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  return query
  update doc_search_requests d
     set status = 'processing', claimed_at = now()
   where d.id = (
     select s.id from doc_search_requests s
      where s.status = 'pending'
      order by s.id
      for update skip locked
      limit 1
   )
  returning d.id, d.query, d.entity_type;
end;
$$;
revoke all on function public.claim_doc_search() from public, anon, authenticated;

-- ── complete (service / edge) ─────────────────────────────────────────────────
create or replace function public.complete_doc_search(
  p_id bigint,
  p_results jsonb default null,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  update doc_search_requests
     set status = case when p_error is not null then 'error' else 'done' end,
         results = p_results,
         error = p_error,
         completed_at = now()
   where id = p_id;
end;
$$;
revoke all on function public.complete_doc_search(bigint, jsonb, text) from public, anon, authenticated;

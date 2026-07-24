-- R9 #127/#133: customer share links + NPS-lite. A dispatcher mints a token;
-- the customer gets a read-only status page for THAT one load (bounded
-- capability, drive-share style — never a listing) and, once it's delivered,
-- a thumbs up/down. Public path is the load-share edge function with the
-- service role; RLS here only governs who mints/sees links and who reads
-- feedback.
create table if not exists public.load_share_links (
  id bigserial primary key,
  token text not null unique,
  load_id bigint not null references public.loads(id) on delete cascade,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '90 days',
  revoked boolean not null default false
);
create index if not exists load_share_links_load_idx on public.load_share_links (load_id);

alter table public.load_share_links enable row level security;
revoke all on table public.load_share_links from anon, authenticated;
grant select, update on public.load_share_links to authenticated;
drop policy if exists lsl_select on public.load_share_links;
create policy lsl_select on public.load_share_links
  for select to authenticated using (public.my_role() in ('admin','dispatcher','accountant'));
drop policy if exists lsl_revoke on public.load_share_links;
create policy lsl_revoke on public.load_share_links
  for update to authenticated
  using (public.my_role() in ('admin','dispatcher'))
  with check (public.my_role() in ('admin','dispatcher'));

-- #133: one thumbs per link, only after the freight actually moved.
create table if not exists public.load_feedback (
  id bigserial primary key,
  load_id bigint not null references public.loads(id) on delete cascade,
  share_id bigint not null unique references public.load_share_links(id) on delete cascade,
  rating text not null check (rating in ('up','down')),
  comment text not null default '',
  created_at timestamptz not null default now()
);
alter table public.load_feedback enable row level security;
revoke all on table public.load_feedback from anon, authenticated;
grant select on public.load_feedback to authenticated;
drop policy if exists lf_select on public.load_feedback;
create policy lf_select on public.load_feedback
  for select to authenticated using (public.my_role() in ('admin','dispatcher','accountant'));

insert into app_private.security_baseline (kind, item) values
  ('grant', 'authenticated load_share_links SELECT'),
  ('grant', 'authenticated load_share_links UPDATE'),
  ('grant', 'authenticated load_feedback SELECT')
on conflict do nothing;

-- Mint (or reuse) the share link for a load. Idempotent: one live link per
-- load, so re-clicking Share never litters tokens.
create or replace function public.create_load_share(p_load_id bigint)
returns text
language plpgsql security definer set search_path = public
as $$
declare tok text;
begin
  if public.my_role() not in ('admin','dispatcher','accountant') then
    raise exception 'Not enough permissions';
  end if;
  if not exists (select 1 from loads where id = p_load_id) then
    raise exception 'Load not found';
  end if;
  select token into tok from load_share_links
   where load_id = p_load_id and not revoked and expires_at > now()
   order by created_at desc limit 1;
  if tok is not null then return tok; end if;
  tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into load_share_links (token, load_id, created_by)
  values (tok, p_load_id, auth.uid());
  return tok;
end;
$$;
revoke all on function public.create_load_share(bigint) from public, anon, authenticated;
grant execute on function public.create_load_share(bigint) to authenticated;

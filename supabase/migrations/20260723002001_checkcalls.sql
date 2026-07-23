-- R9 #121: check-call log. Dispatch's phone notes belong on the load as a
-- timestamped, append-only timeline ("0930 driver loaded, 4 pallets short"),
-- not overwritten prose in the notes field.
create table if not exists public.load_checkcalls (
  id bigserial primary key,
  load_id bigint not null references public.loads(id) on delete cascade,
  note text not null check (length(trim(note)) between 1 and 2000),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists load_checkcalls_load_idx on public.load_checkcalls (load_id, created_at desc);
alter table public.load_checkcalls enable row level security;
revoke all on public.load_checkcalls from anon, authenticated;
grant select, insert on public.load_checkcalls to authenticated;
drop policy if exists lcc_select on public.load_checkcalls;
create policy lcc_select on public.load_checkcalls
  for select to authenticated using (public.my_role() in ('admin','dispatcher','accountant'));
drop policy if exists lcc_insert on public.load_checkcalls;
create policy lcc_insert on public.load_checkcalls
  for insert to authenticated with check (public.my_role() in ('admin','dispatcher'));
insert into app_private.security_baseline (kind, item) values
  ('grant', 'authenticated load_checkcalls SELECT'),
  ('grant', 'authenticated load_checkcalls INSERT')
on conflict do nothing;

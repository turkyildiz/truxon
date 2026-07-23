-- R9 #104: rate-con line items as structured data. The extraction prompt has
-- always summed line haul + fuel surcharge + accessorials into one all-in
-- `loads.rate`; this table keeps the components, which unlocks:
--   • #105 reconciliation (extracted total vs booked rate mismatches)
--   • playbook fuel-surcharge capture (flagged "block 104 territory" in
--     20260722059001_playbook_g_flips.sql)
-- Rows are written from the load-create/edit path when a rate con was scanned
-- (frontend posts fields.line_items) — extract-pdf itself stays stateless.
create table if not exists public.load_line_items (
  id bigserial primary key,
  load_id bigint not null references public.loads(id) on delete cascade,
  kind text not null check (kind in ('line_haul','fuel_surcharge','detention','lumper','stop_pay','other_accessorial')),
  description text not null default '',
  amount numeric(10,2) not null,
  source text not null default 'ratecon_extract' check (source in ('ratecon_extract','manual')),
  created_at timestamptz not null default now()
);
create index if not exists load_line_items_load_idx on public.load_line_items (load_id);
alter table public.load_line_items enable row level security;
revoke all on public.load_line_items from anon, authenticated;
grant select, insert, delete on public.load_line_items to authenticated;
drop policy if exists lli_select on public.load_line_items;
create policy lli_select on public.load_line_items
  for select to authenticated using (public.my_role() in ('admin','dispatcher','accountant'));
drop policy if exists lli_insert on public.load_line_items;
create policy lli_insert on public.load_line_items
  for insert to authenticated with check (public.my_role() in ('admin','dispatcher'));
drop policy if exists lli_delete on public.load_line_items;
create policy lli_delete on public.load_line_items
  for delete to authenticated using (public.my_role() in ('admin','dispatcher'));
insert into app_private.security_baseline (kind, item) values
  ('grant', 'authenticated load_line_items SELECT'),
  ('grant', 'authenticated load_line_items INSERT'),
  ('grant', 'authenticated load_line_items DELETE')
on conflict do nothing;

-- R9 #102: misfiled-doc detector. The NAS 3B re-reads LABELED docs and banks
-- its opinion here; a disagreement ("filed as POD, reads like a rate con")
-- surfaces via sentinel and clears when the office relabels the doc (or a
-- re-audit agrees). Propose-only by construction — nothing auto-relabels a
-- doc a human already filed.
create table if not exists public.doc_label_audits (
  document_id bigint primary key references public.documents(id) on delete cascade,
  stored_type text not null,
  model_type text not null,
  model text not null default '',
  audited_at timestamptz not null default now()
);
alter table public.doc_label_audits enable row level security;
revoke all on public.doc_label_audits from anon, authenticated;
grant select on public.doc_label_audits to authenticated;
drop policy if exists dla_select on public.doc_label_audits;
create policy dla_select on public.doc_label_audits
  for select to authenticated using (public.my_role() in ('admin','dispatcher','accountant'));
insert into app_private.security_baseline (kind, item) values
  ('grant', 'authenticated doc_label_audits SELECT')
on conflict do nothing;

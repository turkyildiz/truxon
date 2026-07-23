-- R9 #30: Denim statement mirror + reconciliation. denim-sync now banks every
-- job it sees (fee, receivable, match) into denim_jobs, so "does Denim's
-- statement agree with our books" becomes a query instead of a shrug:
-- fee mismatches, Denim jobs with no invoice, and invoices we call factored
-- that Denim has no job for.
create table if not exists public.denim_jobs (
  denim_job_id text primary key,
  reference_number text,
  status text,
  fee numeric,
  receivable numeric,
  invoice_id bigint references public.invoices(id) on delete set null,
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists denim_jobs_invoice_idx on public.denim_jobs (invoice_id);
alter table public.denim_jobs enable row level security;
revoke all on public.denim_jobs from anon, authenticated;
grant select on public.denim_jobs to authenticated;
drop policy if exists denim_jobs_select on public.denim_jobs;
create policy denim_jobs_select on public.denim_jobs
  for select to authenticated using (public.my_role() in ('admin','accountant'));
insert into app_private.security_baseline (kind, item)
values ('grant', 'authenticated denim_jobs SELECT')
on conflict do nothing;

create or replace function public.denim_reconciliation()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when auth.role() = 'service_role' or public.my_role() in ('admin','accountant')
  then jsonb_build_object(
    'jobs_seen', (select count(*) from denim_jobs),
    'jobs_matched', (select count(*) from denim_jobs where invoice_id is not null),
    'denim_fees_total', coalesce((select sum(fee) from denim_jobs), 0),
    'captured_fees_total', coalesce((select sum(factoring_fee) from invoices
                                      where factor_name = 'Denim' and factoring_fee is not null), 0),
    'fee_mismatches', coalesce((select jsonb_agg(jsonb_build_object(
        'invoice', i.invoice_number, 'denim_fee', dj.fee, 'captured_fee', i.factoring_fee))
      from denim_jobs dj join invoices i on i.id = dj.invoice_id
      where dj.fee is not null and i.factoring_fee is distinct from dj.fee), '[]'::jsonb),
    'unmatched_jobs', coalesce((select jsonb_agg(jsonb_build_object(
        'job', x.denim_job_id, 'ref', x.reference_number, 'fee', x.fee))
      from (select * from denim_jobs where invoice_id is null
             order by last_seen desc limit 20) x), '[]'::jsonb),
    'factored_without_job', (select count(*) from invoices i
      where i.factor_name = 'Denim' and i.factored_at is not null
        and not exists (select 1 from denim_jobs dj where dj.invoice_id = i.id)),
    'as_of', now())
  end;
$$;
revoke all on function public.denim_reconciliation() from public, anon;
grant execute on function public.denim_reconciliation() to authenticated, service_role;

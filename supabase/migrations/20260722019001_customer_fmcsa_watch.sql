-- R8 Blocks 31/32 — customer authority monitoring. Write-time FMCSA vetting
-- (the _shared/fmcsa.ts gate) proves a number once; nothing ever RE-checked a
-- customer after that. fmcsa-watch gains a weekly 'customers' sweep that
-- re-pulls every customer with an MC/USDOT from QCMobile into this table; the
-- sentinel turns revocations / OOS / name drift into findings.
create table if not exists public.customer_fmcsa_checks (
  customer_id bigint primary key references public.customers (id) on delete cascade,
  checked_at timestamptz not null default now(),
  usdot text not null default '',
  mc text not null default '',
  legal_name text not null default '',
  allowed_to_operate text not null default '',   -- 'Y' / 'N' / ''
  oos_date date,                                 -- out-of-service order date
  name_match boolean,
  raw jsonb
);
alter table public.customer_fmcsa_checks enable row level security;
-- default grants include TRUNCATE for anon/authenticated, which bypasses RLS
-- (the security-posture baseline caught exactly this on first local run)
revoke all on public.customer_fmcsa_checks from anon, authenticated;
grant select on public.customer_fmcsa_checks to authenticated;
drop policy if exists cfc_staff_read on public.customer_fmcsa_checks;
create policy cfc_staff_read on public.customer_fmcsa_checks
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

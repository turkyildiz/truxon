-- Convergence + baseline registration for customer_fmcsa_checks.
--
-- Sequence note (kept honest): 019001 was pushed to prod BEFORE the local
-- suite caught that the new table inherited default TRUNCATE grants for
-- anon/authenticated (TRUNCATE ignores RLS — the posture monitor's whole
-- point). 019001 was then amended locally; prod ran the unamended version, so
-- this migration re-applies the revoke idempotently and registers the one
-- intended grant in the security baseline so posture stays drift-free.
revoke all on public.customer_fmcsa_checks from anon, authenticated;
grant select on public.customer_fmcsa_checks to authenticated;

insert into app_private.security_baseline (kind, item)
values ('grant', 'authenticated customer_fmcsa_checks SELECT')
on conflict do nothing;

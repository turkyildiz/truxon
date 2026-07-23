-- Close the 5 open critical posture_drift findings: on prod the ransomware/
-- lockdown guard TRIGGER functions carry an explicit anon EXECUTE grant
-- (local environments only have the implicit PUBLIC default, which is why the
-- local suite never saw the drift). Triggers run as the table owner regardless
-- of the caller's EXECUTE privilege on the trigger function, so revoking anon
-- changes nothing functionally — it just returns the posture to baseline; the
-- sentinel auto-resolves the findings on its next scan.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('guard_bulk_update','guard_truncate','profiles_lockdown_guard',
                         'guard_bulk_delete','protect_last_admin_delete')
  loop
    execute format('revoke execute on function %s from anon', r.sig);
  end loop;
end $$;

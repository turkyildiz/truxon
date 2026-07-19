-- qbo_status counted the CSRF-placeholder row (inserted when the connect flow
-- STARTS) as "connected", so an aborted OAuth attempt showed Connected with no
-- activity. Connected must mean real tokens: a non-empty realm_id.
create or replace function public.qbo_status()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return (
    select jsonb_build_object(
      'connected', exists (select 1 from qbo_connection where realm_id <> ''),
      'realm_id', (select nullif(realm_id, '') from qbo_connection limit 1),
      'connected_at', (select connected_at from qbo_connection where realm_id <> '' limit 1),
      'backfilled', s.backfilled,
      'last_pull_at', s.last_pull_at,
      'last_error', s.last_error,
      'last_result', s.last_result,
      'qbo_invoices', (select count(*) from invoices where source = 'qbo'),
      'qbo_open_balance', (select coalesce(sum(qbo_balance), 0) from invoices where source = 'qbo' and status = 'sent')
    )
    from qbo_sync_state s where s.id = 1
  );
end;
$$;
revoke all on function public.qbo_status() from public, anon;

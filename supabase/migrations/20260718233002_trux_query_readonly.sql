-- trux_query defense-in-depth: the keyword regex is a model-safety net, not a
-- parser — a "SELECT" can still call side-effecting functions the caller may
-- execute. Making the transaction read-only lets Postgres itself reject any
-- write, whatever shape it arrives in. (Read-write → read-only mid-transaction
-- is allowed; the setting is local to the PostgREST request's transaction.)

create or replace function public.trux_query(p_sql text)
returns jsonb
language plpgsql security invoker
as $$
declare
  q text := btrim(p_sql);
  result jsonb;
begin
  if public.my_role() is null then
    raise exception 'Not authenticated';
  end if;
  if q !~* '^\s*(select|with)\y' then
    raise exception 'Only SELECT queries are allowed';
  end if;
  if q ~* '\m(insert|update|delete|truncate|drop|alter|create|grant|revoke|copy|vacuum|call|do|set|reset|listen|notify|refresh)\M' then
    raise exception 'Query contains a disallowed keyword — read-only SELECT only';
  end if;
  if q like '%;%' then
    raise exception 'Multiple statements are not allowed';
  end if;

  perform set_config('statement_timeout', '4000', true);
  perform set_config('transaction_read_only', 'on', true);

  execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (select * from (%s) q limit 200) t', q)
    into result;
  return result;
end;
$$;

revoke execute on function public.trux_query(text) from public, anon;
grant execute on function public.trux_query(text) to authenticated;

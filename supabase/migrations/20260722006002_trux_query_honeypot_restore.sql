-- Regression fix: 20260722005001 redefined trux_query to add the driver gate
-- but dropped the honeypot decoy-refusal that 20260722001001 had installed —
-- so Forest's SQL tool could read the decoy api_keys/bank_accounts and trip our
-- OWN honeypot wire (false "we're compromised" alarm). This restores BOTH the
-- driver gate AND the decoy refusal in one authoritative definition.
create or replace function public.trux_query(p_sql text)
returns jsonb
language plpgsql security invoker
as $$
declare
  q text := btrim(p_sql);
  v_role public.user_role := public.my_role();
  result jsonb;
begin
  if v_role is null then
    raise exception 'Not authenticated';
  end if;
  if v_role = 'driver' then
    raise exception 'Not enough permissions';
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
  -- Honeypot refusal (from 20260722001001): never let Forest read the decoys and
  -- trip its own tripwire.
  if q ~* '\m(api_keys|bank_accounts|honeypot_hits)\M' or q ~* '_hp_' then
    raise exception 'That table is restricted';
  end if;

  perform set_config('statement_timeout', '4000', true);
  perform set_config('transaction_read_only', 'on', true);

  execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (select * from (%s) q limit 200) t', q)
    into result;
  return result;
end;
$$;

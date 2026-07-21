-- GT-09 — number-sequence RPCs were executable by any authenticated caller,
-- letting a driver login burn invoice/load number gaps for no reason.
--
-- next_invoice_number: only ever called inside SECURITY DEFINER create_invoice
-- (runs as the function owner), so the caller grant can go entirely.
revoke execute on function public.next_invoice_number() from public, anon, authenticated;

-- next_load_number: called from the loads_before_insert trigger, which runs
-- with INVOKER rights — revoking from authenticated would break load creation
-- for office users. Gate inside the function instead: office roles (who can
-- insert loads anyway) and service paths pass; a driver calling the RPC
-- directly to burn numbers is refused.
create or replace function public.next_load_number()
returns text language plpgsql as $$
begin
  if auth.uid() is not null
     and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return 'LD-' || extract(year from now())::text || '-' ||
         lpad(nextval('public.load_number_seq')::text, 4, '0');
end;
$$;

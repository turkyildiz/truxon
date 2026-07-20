-- Customer lifecycle controls: a "Do Not Use" flag alongside active/inactive,
-- and a guarded delete. A customer can only be deleted if we have NEVER hauled
-- their cargo — i.e. no loads and no invoices reference them. Enforced in SQL so
-- the rule can't be bypassed from the client (which has no DELETE policy anyway).

alter table public.customers add column if not exists do_not_use boolean not null default false;

-- Admin-only, guarded delete. Raises a clear message if the customer has any
-- history; otherwise deletes (customer_enrichment_log cascades).
create or replace function public.delete_customer(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loads int;
  v_invoices int;
  v_name text;
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  select company_name into v_name from customers where id = p_id;
  if v_name is null then
    raise exception 'Customer not found';
  end if;
  select count(*) into v_loads from loads where customer_id = p_id;
  select count(*) into v_invoices from invoices where customer_id = p_id;
  if v_loads > 0 or v_invoices > 0 then
    raise exception 'Cannot delete "%": % load(s) and % invoice(s) on record — we have hauled their cargo. Mark them Inactive or Do Not Use instead.',
      v_name, v_loads, v_invoices;
  end if;
  delete from customers where id = p_id;
end;
$$;

revoke all on function public.delete_customer(bigint) from public, anon;
grant execute on function public.delete_customer(bigint) to authenticated;

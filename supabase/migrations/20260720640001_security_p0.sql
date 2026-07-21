-- R12 #7 — Security P0 batch (from docs/Truxon_Code_Security_Scrutiny_Report):
-- S-06: my_role() now RAISES 'Account disabled' for inactive (or missing)
--       profiles — every RLS policy and every role gate fails closed for
--       deactivated accounts. Service/cron callers (auth.uid() null) keep
--       getting NULL exactly as before.
-- S-07: customer_pay_profile() gains a role gate (was open to any staff).
-- S-12: DB-level last-active-admin trigger (edge fn was the only guard).
-- B-01: void_invoice reopens invoiced accessorials so a re-bill keeps them.
-- B-02: create_invoice row-locks the accessorials it sums and invoices only
--       those ids. B-03: proposals refresh amounts while still 'proposed'.
-- create_invoice / propose reproduced WHOLE from 20260720530001;
-- customer_pay_profile from 20260720570001; void_invoice from 20260718233001.

create or replace function public.my_role()
returns public.user_role
language plpgsql stable security definer set search_path = public
as $$
declare v_role public.user_role; v_active boolean;
begin
  if auth.uid() is null then
    return null;  -- service/cron path, unchanged
  end if;
  select p.role, p.is_active into v_role, v_active from public.profiles p where p.id = auth.uid();
  if v_active is distinct from true then
    raise exception 'Account disabled';
  end if;
  return v_role;
end;
$$;

drop function if exists public.customer_pay_profile();
create function public.customer_pay_profile()
returns table (customer_id bigint, customer text, avg_days numeric, paid_count int)
language plpgsql security definer set search_path = public stable
as $$
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  return query
  select i.customer_id,
         c.company_name,
         round(avg(extract(epoch from (i.paid_at - i.invoice_date)) / 86400.0)::numeric, 1),
         count(*)::int
  from public.invoices i
  join public.customers c on c.id = i.customer_id
  where i.status = 'paid' and i.paid_at is not null
    and i.invoice_date > now() - interval '365 days'
  group by i.customer_id, c.company_name;
end;
$$;
revoke all on function public.customer_pay_profile() from public, anon;
grant execute on function public.customer_pay_profile() to authenticated, service_role;

-- S-12: the LAST active admin cannot be demoted or deactivated, at the DB level
create or replace function public.protect_last_admin()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.role = 'admin' and old.is_active
     and (new.role <> 'admin' or not new.is_active) then
    if (select count(*) from public.profiles
         where role = 'admin' and is_active and id <> old.id) = 0 then
      raise exception 'Cannot demote or deactivate the last active admin';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_protect_last_admin on public.profiles;
create trigger profiles_protect_last_admin
  before update of role, is_active on public.profiles
  for each row execute function public.protect_last_admin();

-- B-01: void reopens the accessorials that rode the voided invoice
create or replace function public.void_invoice(p_invoice_id bigint)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  inv public.invoices;
  voided_ids bigint[];
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select * into inv from public.invoices where id = p_invoice_id for update;
  if not found then
    raise exception 'Invoice not found';
  end if;
  if inv.status = 'paid' then
    raise exception 'Cannot void a paid invoice';
  end if;
  if inv.status = 'void' then
    raise exception 'Invoice is already voided';
  end if;

  select coalesce(array_agg(id), '{}') into voided_ids from public.loads where invoice_id = p_invoice_id;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set invoice_id = null, status = 'completed' where id = any(voided_ids);
  perform set_config('app.load_rpc', '', true);

  update public.invoices set status = 'void' where id = p_invoice_id;

  -- reopen accessorials so the next create_invoice folds them back in (B-01)
  update public.load_accessorials
     set status = 'approved'
   where load_id = any(voided_ids) and status = 'invoiced';

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  select 'load', id, auth.uid(), 'status_changed', 'billed → completed (invoice ' || inv.invoice_number || ' voided)'
    from unnest(voided_ids) as id;
  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('invoice', inv.id, auth.uid(), 'voided', inv.invoice_number || ' voided; its loads reverted to completed; accessorials reopened');
end;
$$;

CREATE OR REPLACE FUNCTION public.create_invoice(p_customer_id bigint, p_load_ids bigint[], p_due_date timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS invoices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  inv public.invoices;
  l record;
  v_total numeric(12,2) := 0;
  v_acc numeric(12,2) := 0;
  v_acc_ids bigint[];
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  if array_length(p_load_ids, 1) is null then
    raise exception 'Select at least one load';
  end if;

  for l in select * from public.loads where id = any(p_load_ids) for update loop
    if l.customer_id <> p_customer_id then
      raise exception '% belongs to a different customer', l.load_number;
    end if;
    if l.status <> 'completed' then
      raise exception '% is not completed', l.load_number;
    end if;
    if l.invoice_id is not null then
      raise exception '% is already invoiced', l.load_number;
    end if;
    v_total := v_total + l.rate;
  end loop;

  if (select count(*) from public.loads where id = any(p_load_ids)) <> cardinality(p_load_ids) then
    raise exception 'One or more loads not found';
  end if;

  -- approved accessorials (detention etc.) ride the same invoice — row-locked
  -- so a concurrent decide_accessorial cannot desync totals from statuses (B-02)
  select coalesce(array_agg(a.id), '{}'), coalesce(sum(a.amount), 0)
    into v_acc_ids, v_acc
    from (select la.id, la.amount from public.load_accessorials la
           where la.load_id = any(p_load_ids) and la.status = 'approved'
           for update) a;
  v_total := v_total + v_acc;

  insert into public.invoices (invoice_number, customer_id, due_date, total)
  values (public.next_invoice_number(), p_customer_id, p_due_date, v_total)
  returning * into inv;

  update public.load_accessorials
     set status = 'invoiced', decided_at = now()
   where id = any(v_acc_ids);

  perform set_config('app.load_rpc', '1', true);
  update public.loads set invoice_id = inv.id, status = 'billed' where id = any(p_load_ids);
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  select 'load', id, auth.uid(), 'status_changed', 'completed → billed (' || inv.invoice_number || ')'
    from public.loads where id = any(p_load_ids);

  return inv;
end;
$function$;

create or replace function public.propose_detention_accessorials(p_days int default 45)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_added int := 0;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  insert into load_accessorials (load_id, atype, stop_type, amount, minutes, detail)
  select d.load_id, 'detention', d.stop_type, d.est_pay, d.detention_min,
         format('%s dwell %s min at %s — %s min over free time',
                d.stop_type, d.dwell_min, coalesce(d.stop_state, '?'), d.detention_min)
    from public.detention_events(p_days) d
   where d.est_pay > 0
  on conflict (load_id, atype, stop_type) do update
     set amount = excluded.amount, minutes = excluded.minutes, detail = excluded.detail
   where load_accessorials.status = 'proposed';  -- refresh frozen amounts (B-03)
  get diagnostics v_added = row_count;
  return v_added;
end;
$$;

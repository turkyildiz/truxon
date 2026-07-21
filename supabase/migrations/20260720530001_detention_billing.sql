-- Detention → billing. Detection (detention_events) has been live since
-- tonight's earlier work; this closes the loop to money: detected detention
-- lands in load_accessorials as 'proposed', the office approves or rejects it
-- on the ⏱️ tab, and create_invoice folds every APPROVED accessorial into the
-- invoice total when the load is billed (then marks it 'invoiced'). Amounts
-- are always server-recomputed from detention_events — the client cannot
-- invent a number.

create table if not exists public.load_accessorials (
  id bigint generated always as identity primary key,
  load_id bigint not null references public.loads(id) on delete cascade,
  atype text not null default 'detention'
    check (atype in ('detention', 'lumper', 'tonu', 'layover')),
  stop_type text check (stop_type in ('pickup', 'delivery')),
  amount numeric(12,2) not null check (amount >= 0),
  minutes int,
  detail text not null default '',
  status text not null default 'proposed'
    check (status in ('proposed', 'approved', 'rejected', 'invoiced')),
  decided_by uuid references public.profiles(id),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  unique (load_id, atype, stop_type)
);
alter table public.load_accessorials enable row level security;
grant select on public.load_accessorials to authenticated;
drop policy if exists load_accessorials_read on public.load_accessorials;
create policy load_accessorials_read on public.load_accessorials
  for select using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

-- detected detention → proposed accessorials (idempotent; service or office)
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
  on conflict (load_id, atype, stop_type) do nothing;
  get diagnostics v_added = row_count;
  return v_added;
end;
$$;
revoke all on function public.propose_detention_accessorials(int) from public, anon;
grant execute on function public.propose_detention_accessorials(int) to authenticated, service_role;

-- office decision; invoiced rows are immutable
create or replace function public.decide_accessorial(p_id bigint, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_status text;
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select status into v_status from load_accessorials where id = p_id for update;
  if v_status is null then raise exception 'Accessorial not found'; end if;
  if v_status = 'invoiced' then raise exception 'Already invoiced'; end if;
  update load_accessorials
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now()
   where id = p_id;
end;
$$;
revoke all on function public.decide_accessorial(bigint, boolean) from public, anon;
grant execute on function public.decide_accessorial(bigint, boolean) to authenticated;

-- daily cron keeps proposals current with fresh ELD/geocode data
do $do$ begin perform cron.unschedule('truxon-detention-propose'); exception when others then null; end $do$;
select cron.schedule('truxon-detention-propose', '51 6 * * *',
  $$select public.propose_detention_accessorials()$$);
select public.propose_detention_accessorials();

-- create_invoice reproduced from the CURRENT live definition + accessorial fold

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

  -- approved accessorials (detention etc.) ride the same invoice
  select coalesce(sum(a.amount), 0) into v_acc
    from public.load_accessorials a
   where a.load_id = any(p_load_ids) and a.status = 'approved';
  v_total := v_total + v_acc;

  insert into public.invoices (invoice_number, customer_id, due_date, total)
  values (public.next_invoice_number(), p_customer_id, p_due_date, v_total)
  returning * into inv;

  update public.load_accessorials
     set status = 'invoiced', decided_at = now()
   where load_id = any(p_load_ids) and status = 'approved';

  perform set_config('app.load_rpc', '1', true);
  update public.loads set invoice_id = inv.id, status = 'billed' where id = any(p_load_ids);
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  select 'load', id, auth.uid(), 'status_changed', 'completed → billed (' || inv.invoice_number || ')'
    from public.loads where id = any(p_load_ids);

  return inv;
end;
$function$;

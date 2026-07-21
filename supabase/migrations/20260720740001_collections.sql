-- R3 #1 — Collections workroom. $156K is outstanding and 79 invoices are past
-- due; this gives the owner a prioritized call list, an append-only
-- promise-to-pay ledger, and weekly Forest dunning DRAFTS into the shadow
-- feed (review-only — nothing is ever sent automatically).

-- ---------- promise-to-pay / call-note ledger ----------
create table public.collection_notes (
  id bigint generated always as identity primary key,
  customer_id bigint not null references public.customers (id) on delete cascade,
  invoice_id bigint references public.invoices (id) on delete set null,
  note text not null,
  promised_amount numeric(12,2),
  promised_date date,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index collection_notes_customer_idx on public.collection_notes (customer_id, created_at desc);
alter table public.collection_notes enable row level security;

-- Append-only: office can read and add; no update/delete policies — a
-- collections history that can be rewritten is worthless in a dispute.
create policy collection_notes_select on public.collection_notes
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));
create policy collection_notes_insert on public.collection_notes
  for insert to authenticated
  with check (public.my_role() in ('admin', 'dispatcher', 'accountant'));

-- ---------- prioritized queue ----------
-- One row per customer with overdue sent invoices. Priority = dollars × age
-- pressure, so a $30K/60-day account outranks a $2K/90-day one.
create function public.collections_queue()
returns table (
  customer_id bigint,
  company_name text,
  contact_person text,
  phone text,
  email text,
  overdue_total numeric,
  overdue_count int,
  oldest_days int,
  avg_days_to_pay numeric,
  last_promise jsonb,
  invoices jsonb,
  priority numeric
)
language plpgsql security definer set search_path = public stable
as $$
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return query
  with overdue as (
    select i.customer_id as cid,
           sum(public.invoice_balance(i)) as total,
           count(*)::int as cnt,
           max(extract(day from now() - i.due_date))::int as oldest,
           jsonb_agg(jsonb_build_object(
             'invoice_id', i.id,
             'invoice_number', i.invoice_number,
             'balance', public.invoice_balance(i),
             'due_date', i.due_date::date,
             'days_late', extract(day from now() - i.due_date)::int
           ) order by i.due_date) as invs
    from public.invoices i
    where i.status = 'sent' and i.due_date < now()
      and public.invoice_balance(i) > 0
    group by i.customer_id
  )
  select o.cid, c.company_name, c.contact_person, c.phone, c.email,
         o.total, o.cnt, o.oldest,
         (select p.avg_days from public.customer_pay_profile() p where p.customer_id = o.cid),
         (select jsonb_build_object('note', n.note, 'promised_amount', n.promised_amount,
                                    'promised_date', n.promised_date, 'created_at', n.created_at)
            from public.collection_notes n
           where n.customer_id = o.cid
           order by n.created_at desc limit 1),
         o.invs,
         round(o.total * (1 + o.oldest / 30.0), 2)
  from overdue o
  join public.customers c on c.id = o.cid
  order by o.total * (1 + o.oldest / 30.0) desc;
end;
$$;
revoke all on function public.collections_queue() from public, anon;
grant execute on function public.collections_queue() to authenticated, service_role;

-- ---------- weekly Forest dunning drafts (shadow feed, never sent) ----------
-- One draft per customer per ISO week, only for accounts ≥5 days late.
-- Lands in trux_observations as a draft_reply the owner reviews on /shadow.
create function public.draft_dunning_notices()
returns int
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  v_body text;
  v_count int := 0;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  for r in
    select * from public.collections_queue() q where q.oldest_days >= 5
  loop
    v_body := format(
      'Hi %s,' || E'\n\n' ||
      'A friendly reminder from Aida Logistics: %s invoice%s totaling %s %s past due.' || E'\n\n%s\n' ||
      'Could you let us know when payment is scheduled? Happy to resend any paperwork.' || E'\n\n' ||
      'Thank you,' || E'\n' || 'Aida Logistics LLC',
      coalesce(nullif(r.contact_person, ''), r.company_name),
      r.overdue_count, case when r.overdue_count = 1 then ' is' else 's are' end,
      '$' || round(r.overdue_total)::text,
      case when r.oldest_days >= 30 then format('(oldest %s days)', r.oldest_days) else '' end,
      (select string_agg(format('  • %s — $%s, due %s (%s days late)',
                                v->>'invoice_number', round((v->>'balance')::numeric),
                                v->>'due_date', v->>'days_late'), E'\n')
         from jsonb_array_elements(r.invoices) v));
    insert into public.trux_observations
      (message_id, received_at, sender_email, sender_name, subject,
       classification, summary, extracted, would_action, would_detail,
       confidence, matched_customer_id)
    values
      ('dunning:' || r.customer_id || ':' || to_char(current_date, 'IYYY-IW'),
       now(), 'forest@truxon.com', 'Forest',
       format('💰 Dunning draft — %s ($%s overdue)', r.company_name, round(r.overdue_total)),
       'payment',
       format('%s: %s invoices, $%s overdue, oldest %s days. Draft reminder ready for review.',
              r.company_name, r.overdue_count, round(r.overdue_total), r.oldest_days),
       jsonb_build_object('customer_id', r.customer_id, 'overdue_total', r.overdue_total,
                          'invoices', r.invoices, 'email', r.email),
       'draft_reply', v_body, 'high', r.customer_id)
    on conflict (message_id) do nothing;
    if found then v_count := v_count + 1; end if;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.draft_dunning_notices() from public, anon, authenticated;
grant execute on function public.draft_dunning_notices() to service_role;

-- Monday 13:10 UTC (8:10am local), right after the weekly digest.
do $$ begin perform cron.unschedule('truxon-dunning-drafts'); exception when others then null; end $$;
select cron.schedule('truxon-dunning-drafts', '10 13 * * 1',
  $job$select public.draft_dunning_notices()$job$);

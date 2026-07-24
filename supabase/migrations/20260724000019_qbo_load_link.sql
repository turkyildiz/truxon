-- QBO invoice → load linkage (fixes the "unbilled" list showing already-invoiced loads).
--
-- Root cause: loads.invoice_id was never populated, so acct_unbilled_loads()'s
-- `status='completed' AND invoice_id IS NULL` filter degenerated to "every
-- completed load" — including loads QBO has already invoiced (and collected).
-- The QBO mirror (qbo_upsert_invoices) also dropped the invoice line items, so
-- nothing carried the "LOAD <ref>" text that ties a QBO invoice to a Truxon
-- load by reference_number.
--
-- This migration:
--   1. Adds invoices.qbo_load_refs (the LOAD <ref> tokens off the QBO lines).
--   2. Teaches qbo_upsert_invoices to persist them.
--   3. Adds acct_reconcile_qbo_billing(): matches completed+unbilled loads to a
--      non-void QBO mirror invoice by normalized reference and, through the
--      sanctioned app.load_rpc guard, sets invoice_id + status='billed'. It is
--      the same state change create_invoice() makes, just sourced from QBO.
--
-- Billing truth stays QBO. This only reflects, in Truxon, what QBO already did.

alter table public.invoices add column if not exists qbo_load_refs text[];

comment on column public.invoices.qbo_load_refs is
  'LOAD <ref> tokens parsed from the QBO invoice line descriptions; ties a mirrored QBO invoice to Truxon loads by loads.reference_number.';

-- Reference normaliser: QBO "LOAD 0011178" and a load reference_number of
-- "11178" must match. Upper-case, strip whitespace, and drop leading zeros on
-- pure-digit refs; hyphenated/alphanumeric refs (e.g. 3922-0081-1025, S4159285)
-- are left as-is apart from case/space. Empty → null (never matches).
create or replace function public._norm_ref(p text)
returns text
language sql
immutable
as $$
  select case
    when p is null then null
    else (
      with cleaned as (select regexp_replace(upper(trim(p)), '\s+', '', 'g') as s)
      select nullif(
        case when s ~ '^\d+$' then ltrim(s, '0') else s end,
        ''
      ) from cleaned
    )
  end;
$$;

-- Recreate the mirror upsert to also persist load_refs (everything else is the
-- 20260719440001 body verbatim, so re-applying is safe).
create or replace function public.qbo_upsert_invoices(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  v_cust bigint;
  v_inv bigint;
  v_ins int := 0;
  v_upd int := 0;
  v_cust_new int := 0;
  v_refs text[];
begin
  -- service only (post-rotation convention: service calls carry no user)
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_refs := case
      when r ? 'load_refs'
        then (select coalesce(array_agg(x), '{}') from jsonb_array_elements_text(r->'load_refs') as x)
      else null
    end;

    -- match customer: by qbo_id, then the merged-alias ledger, then exact name
    -- (case-insensitive), else create
    select id into v_cust from customers where qbo_id = r->>'customer_qbo_id';
    if v_cust is null then
      select customer_id into v_cust from customer_qbo_aliases where qbo_id = r->>'customer_qbo_id';
    end if;
    if v_cust is null then
      select id into v_cust from customers
        where lower(company_name) = lower(r->>'customer_name')
        order by id limit 1;
      if v_cust is not null then
        update customers set qbo_id = r->>'customer_qbo_id' where id = v_cust and qbo_id is null;
      else
        insert into customers (company_name, qbo_id)
          values (r->>'customer_name', r->>'customer_qbo_id')
          returning id into v_cust;
        v_cust_new := v_cust_new + 1;
      end if;
    end if;

    select id into v_inv from invoices where qbo_id = r->>'qbo_id';
    if v_inv is null then
      insert into invoices (invoice_number, customer_id, invoice_date, due_date, total,
                            status, source, qbo_id, qbo_doc_number, qbo_balance, qbo_synced_at,
                            qbo_load_refs)
      values (
        'QBO-' || (r->>'doc_number'),
        v_cust,
        (r->>'txn_date')::timestamptz,
        (r->>'due_date')::timestamptz,
        (r->>'total')::numeric,
        case
          when (r->>'voided')::boolean then 'void'
          when (r->>'balance')::numeric = 0 then 'paid'
          else 'sent'
        end::invoice_status,
        'qbo', r->>'qbo_id', r->>'doc_number',
        (r->>'balance')::numeric, now(),
        v_refs
      );
      v_ins := v_ins + 1;
    else
      -- update the mirror; flip paid/void from the books, but never resurrect
      -- a void and never touch a Truxon-side draft's numbering. When we OBSERVE
      -- the sent→paid flip, stamp paid_at (sync cadence ≈ 30 min, so this
      -- approximates the payment recording time) so pay profiles can learn.
      -- Only overwrite load_refs when this payload carried them (never blank an
      -- existing set).
      update invoices set
        total = (r->>'total')::numeric,
        due_date = (r->>'due_date')::timestamptz,
        qbo_doc_number = r->>'doc_number',
        qbo_balance = (r->>'balance')::numeric,
        qbo_synced_at = now(),
        qbo_load_refs = coalesce(v_refs, qbo_load_refs),
        paid_at = case
          when not (r->>'voided')::boolean and status <> 'void' and status <> 'paid'
               and (r->>'balance')::numeric = 0 then coalesce(paid_at, now())
          else paid_at
        end,
        status = case
          when (r->>'voided')::boolean then 'void'::invoice_status
          when status = 'void' then status
          when (r->>'balance')::numeric = 0 then 'paid'::invoice_status
          when status = 'paid' and (r->>'balance')::numeric > 0 then 'sent'::invoice_status
          else status
        end
      where id = v_inv;
      v_upd := v_upd + 1;
    end if;
  end loop;

  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'customers_created', v_cust_new);
end;
$$;
revoke all on function public.qbo_upsert_invoices(jsonb) from public, anon, authenticated;

-- One-time / catch-up setter for existing mirror rows that predate load_refs
-- capture. p_rows: [{ "doc_number": "3418", "load_refs": ["3922-0081-1025"] }].
-- Service (no user) or admin. Never touches non-QBO invoices.
create or replace function public.qbo_backfill_load_refs(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  v_n int := 0;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    update invoices
      set qbo_load_refs = (select coalesce(array_agg(x), '{}')
                             from jsonb_array_elements_text(r->'load_refs') as x)
      where source = 'qbo'
        and qbo_doc_number = (r->>'doc_number')
        and coalesce(qbo_load_refs, '{}') = '{}';
    v_n := v_n + (case when found then 1 else 0 end);
  end loop;
  return v_n;
end;
$$;
-- Callable by an admin JWT or a service (no-user) context; the body guards admin.
revoke all on function public.qbo_backfill_load_refs(jsonb) from public, anon;

-- Reflect QBO's billing state onto loads: any completed, not-yet-invoiced load
-- whose reference_number matches a LOAD <ref> on a live (non-void) QBO mirror
-- invoice is linked to that invoice and marked billed — the same transition
-- create_invoice() performs, sourced from QBO instead of a Truxon-drawn invoice.
-- Dry-run by default: returns exactly what it WOULD change and mutates nothing.
create or replace function public.acct_reconcile_qbo_billing(p_dry_run boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_matches jsonb;
  v_count int;
  v_total numeric;
  v_unmatched int;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  -- Best single QBO invoice per candidate load: prefer a paid one, then lowest id.
  with cand as (
    select l.id as load_id, l.load_number, l.reference_number, l.rate
    from loads l
    where l.status = 'completed'
      and l.invoice_id is null
      and public._norm_ref(l.reference_number) is not null
  ),
  m as (
    select c.load_id, c.load_number, c.reference_number, c.rate,
           i.id as invoice_id, i.qbo_doc_number, i.total as invoice_total, i.status as invoice_status,
           row_number() over (
             partition by c.load_id
             order by (i.status = 'paid') desc, i.id
           ) as rn
    from cand c
    join invoices i
      on i.source = 'qbo'
     and i.status <> 'void'
     and exists (
       select 1 from unnest(coalesce(i.qbo_load_refs, '{}'::text[])) as ref
       where public._norm_ref(ref) = public._norm_ref(c.reference_number)
     )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'load_id', load_id, 'load_number', load_number, 'reference', reference_number,
           'rate', rate, 'invoice_id', invoice_id, 'qbo_doc', qbo_doc_number,
           'invoice_total', invoice_total, 'invoice_status', invoice_status::text,
           'amount_matches', abs(coalesce(invoice_total, 0) - coalesce(rate, 0)) < 0.5
         ) order by rate desc), '[]'::jsonb)
    into v_matches
  from m where rn = 1;

  v_count := jsonb_array_length(v_matches);
  select coalesce(sum((e->>'rate')::numeric), 0) into v_total
    from jsonb_array_elements(v_matches) as e;

  select count(*) into v_unmatched
  from loads l
  where l.status = 'completed'
    and l.invoice_id is null
    and not exists (
      select 1 from jsonb_array_elements(v_matches) as e
      where (e->>'load_id')::bigint = l.id
    );

  if not p_dry_run and v_count > 0 then
    perform set_config('app.load_rpc', '1', true);
    update loads l
       set invoice_id = (e->>'invoice_id')::bigint,
           status = 'billed'
      from jsonb_array_elements(v_matches) as e
     where l.id = (e->>'load_id')::bigint;
    perform set_config('app.load_rpc', '', true);

    insert into activity_log (entity_type, entity_id, user_id, action, detail)
    select 'load', (e->>'load_id')::bigint, auth.uid(), 'status_changed',
           'completed → billed (QBO ' || (e->>'qbo_doc') || ')'
      from jsonb_array_elements(v_matches) as e;
  end if;

  return jsonb_build_object(
    'dry_run', p_dry_run,
    'matched', v_count,
    'matched_total', v_total,
    'still_unbilled', v_unmatched,
    'linked', case when p_dry_run then 0 else v_count end,
    'rows', v_matches
  );
end;
$$;
revoke all on function public.acct_reconcile_qbo_billing(boolean) from public, anon;

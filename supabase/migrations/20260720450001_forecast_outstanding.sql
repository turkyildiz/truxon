-- Bug fix (reported by owner): the Forecast tab listed QBO-mirror invoices as
-- open at FULL total — but most are actually paid, with only small factoring-fee
-- residuals left open in the QBO books (e.g. $132.95 of $2,600). Measured on
-- prod: 158 'sent' mirror rows, many with 2-5% residual balances; zero were
-- number-mismatch duplicates.
-- Fixes, applied consistently across the predictive layer:
--   1. OUTSTANDING, not total: qbo_balance for mirror rows; total − recorded
--      payments for native rows.
--   2. Residual noise gate: an invoice with ≤$200 open AND ≤10% of its total is
--      a fee remnant / write-off item, not a collection risk — excluded from
--      slow-pay (still counted, honestly small, in expected cash).
--   3. Display the real doc number ('#4523'), not the 'QBO-4523' mirror key.
--   4. qbo_upsert_invoices stamps paid_at when it OBSERVES a sent→paid flip
--      (sync runs every 30 min, so observation time ≈ payment recording time),
--      so mirror invoices start feeding customer_pay_profile. Historical
--      already-paid imports stay paid_at null — we don't fabricate dates.

-- ── slow_pay_risk: adds `outstanding` (return signature changes → drop first) ──
drop function if exists public.slow_pay_risk();
create function public.slow_pay_risk()
returns table (
  invoice_id bigint, invoice_number text, customer text, customer_id bigint,
  total numeric, outstanding numeric, invoice_date timestamptz, due_date timestamptz,
  avg_days numeric, predicted_pay_date date, predicted_days_late int, risk text
)
language plpgsql security definer set search_path = public stable as $$
declare v_dso numeric;
begin
  if public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(round(avg(cpp.avg_days), 1), 30) into v_dso from public.customer_pay_profile() cpp;
  return query
  with prof as (select * from public.customer_pay_profile()),
       pay as (select p.invoice_id, sum(p.amount) as paid from public.invoice_payments p group by p.invoice_id),
       open_inv as (
         select i.*,
                case when i.invoice_number like 'QBO-%'
                     then '#'||coalesce(nullif(i.qbo_doc_number,''), substring(i.invoice_number from 5))
                     else i.invoice_number end as display_number,
                round(case when i.source = 'qbo' and i.qbo_balance is not null then i.qbo_balance
                           else i.total - coalesce(pay.paid, 0) end, 2) as open_amt
           from public.invoices i left join pay on pay.invoice_id = i.id
          where i.status = 'sent'
       )
  select i.id, i.display_number, c.company_name, i.customer_id, i.total, i.open_amt,
         i.invoice_date, i.due_date,
         coalesce(p.avg_days, v_dso) as ad,
         (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int) as ppd,
         greatest(0, (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int)
                     - coalesce(i.due_date::date, i.invoice_date::date + 30))::int as late,
         case
           when greatest(0, (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int)
                            - coalesce(i.due_date::date, i.invoice_date::date + 30)) > 15 then 'high'
           when (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int)
                    > coalesce(i.due_date::date, i.invoice_date::date + 30) then 'medium'
           else 'low'
         end as risk
  from open_inv i
  join public.customers c on c.id = i.customer_id
  left join prof p on p.customer_id = i.customer_id
  where i.open_amt >= 1
    and not (i.open_amt <= 200 and i.open_amt <= 0.10 * i.total)   -- fee residual, not a risk
  order by late desc, i.open_amt desc;
end;
$$;
revoke all on function public.slow_pay_risk() from public, anon;
grant execute on function public.slow_pay_risk() to authenticated;

-- ── cashflow_forecast: money IN from OUTSTANDING amounts (signature unchanged) ──
create or replace function public.cashflow_forecast(p_weeks int default 8)
returns table (
  week_start date, week_number int, week_label text,
  expected_in numeric, expected_out numeric, net numeric, cumulative_net numeric
)
language plpgsql security definer set search_path = public stable as $$
declare
  v_dso numeric;
  v_fuel_wk numeric;
  v_fixed_wk numeric;
  v_driver_wk numeric;
  v_toll_wk numeric;
  v_maint_wk numeric;
  v_out_wk numeric;
begin
  if public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(round(avg(cpp.avg_days), 1), 30) into v_dso from public.customer_pay_profile() cpp;

  -- trailing 8-week (56-day) cost averages
  select coalesce(sum(coalesce(net_of_discount, amount)), 0) / 8.0 into v_fuel_wk
    from public.fuel_transactions
   where status <> 'Declined' and transaction_time > now() - interval '56 days';
  select coalesce(sum(l.miles * d.pay_per_mile), 0) / 8.0 into v_driver_wk
    from public.loads l join public.drivers d on d.id = l.driver_id
   where l.status in ('completed', 'billed') and l.delivery_time > now() - interval '56 days';
  select coalesce(sum(monthly_cost), 0) / 4.33 into v_fixed_wk
    from public.trucks where status <> 'retired';
  select coalesce(sum(t.toll_charge), 0) / 8.0 into v_toll_wk
    from public.toll_transactions t
   where coalesce(t.post_date_time, t.exit_date_time) > now() - interval '56 days';
  select coalesce(sum(m.cost), 0) / 8.0 into v_maint_wk
    from public.maintenance_records m
   where m.status = 'completed' and m.date_completed > current_date - 56;
  v_out_wk := round(coalesce(v_fuel_wk, 0) + coalesce(v_driver_wk, 0) + coalesce(v_fixed_wk, 0)
                    + coalesce(v_toll_wk, 0) + coalesce(v_maint_wk, 0), 2);

  return query
  with weeks as (
    select public.trux_week_start(current_date) + (g * 7) as ws
    from generate_series(0, greatest(p_weeks, 1) - 1) g
  ),
  prof as (select * from public.customer_pay_profile()),
  pay as (select p2.invoice_id, sum(p2.amount) as paid from public.invoice_payments p2 group by p2.invoice_id),
  -- money IN from open invoices at their OUTSTANDING amount, landed in the week
  -- of their predicted pay date
  inv_in as (
    select public.trux_week_start(
             greatest(i.invoice_date::date + coalesce(p.avg_days, v_dso)::int, current_date)) as ws,
           sum(case when i.source = 'qbo' and i.qbo_balance is not null then i.qbo_balance
                    else i.total - coalesce(pay.paid, 0) end) as amt
      from public.invoices i
      left join prof p on p.customer_id = i.customer_id
      left join pay on pay.invoice_id = i.id
     where i.status = 'sent'
       and (case when i.source = 'qbo' and i.qbo_balance is not null then i.qbo_balance
                 else i.total - coalesce(pay.paid, 0) end) > 0
     group by 1
  ),
  -- money IN from delivered-but-unbilled loads (invoice ~3 days out, then pay lag)
  unbilled_in as (
    select public.trux_week_start(
             greatest(l.delivery_time::date + 3 + coalesce(p.avg_days, v_dso)::int, current_date)) as ws,
           sum(l.rate) as amt
      from public.loads l left join prof p on p.customer_id = l.customer_id
     where l.status = 'completed' and l.invoice_id is null and l.delivery_time is not null
     group by 1
  )
  select w.ws,
         public.trux_week_number(w.ws),
         public.trux_week_label(w.ws),
         round(coalesce(ii.amt, 0) + coalesce(ui.amt, 0), 2) as expected_in,
         v_out_wk as expected_out,
         round(coalesce(ii.amt, 0) + coalesce(ui.amt, 0) - v_out_wk, 2) as net,
         round(sum(coalesce(ii.amt, 0) + coalesce(ui.amt, 0) - v_out_wk)
                 over (order by w.ws rows between unbounded preceding and current row), 2) as cumulative_net
  from weeks w
  left join inv_in ii on ii.ws = w.ws
  left join unbilled_in ui on ui.ws = w.ws
  order by w.ws;
end;
$$;
revoke all on function public.cashflow_forecast(int) from public, anon;
grant execute on function public.cashflow_forecast(int) to authenticated;

-- ── qbo_upsert_invoices: stamp paid_at on an OBSERVED sent→paid flip ─────────
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
begin
  -- service only (post-rotation convention: service calls carry no user)
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
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
                            status, source, qbo_id, qbo_doc_number, qbo_balance, qbo_synced_at)
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
        (r->>'balance')::numeric, now()
      );
      v_ins := v_ins + 1;
    else
      -- update the mirror; flip paid/void from the books, but never resurrect
      -- a void and never touch a Truxon-side draft's numbering. When we OBSERVE
      -- the sent→paid flip, stamp paid_at (sync cadence ≈ 30 min, so this
      -- approximates the payment recording time) so pay profiles can learn.
      update invoices set
        total = (r->>'total')::numeric,
        due_date = (r->>'due_date')::timestamptz,
        qbo_doc_number = r->>'doc_number',
        qbo_balance = (r->>'balance')::numeric,
        qbo_synced_at = now(),
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

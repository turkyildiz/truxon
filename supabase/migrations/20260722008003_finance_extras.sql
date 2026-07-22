-- Playbook march, Financial cluster (R6 block 4). finance_extras() computes the
-- rows the accessorial/detention pipeline + invoice ledger now support; three
-- more rows flip onto ALREADY-live computations (EBITDA, EBITDA margin, quick
-- ratio) that just never had their playbook pointer set.
create or replace function public.finance_extras()
returns jsonb
language plpgsql security definer set search_path = public stable
as $$
declare out jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  out := jsonb_build_object(
    -- #15 Accessorial Revenue (trailing 90d, invoiced)
    'accessorial_revenue_90d', coalesce((select sum(a.amount) from public.load_accessorials a
        where a.status = 'invoiced' and a.decided_at >= now() - interval '90 days'), 0),
    -- #71 Detention Capture Rate % — of proposals DECIDED in the window, the
    -- share the office captured (approved or invoiced) vs rejected. Undecided
    -- proposals are excluded (they're the review-queue nudge's job).
    'detention_capture_rate_pct', (select case when count(*) > 0
        then round(100.0 * count(*) filter (where a.status in ('approved','invoiced')) / count(*), 1)
        else null end
        from public.load_accessorials a
       where a.atype = 'detention' and a.status in ('approved','invoiced','rejected')
         and a.decided_at >= now() - interval '90 days'),
    -- #75 Billing Lag (days) — delivery → invoice, loads delivered last 90d
    'billing_lag_days', (select round(avg(extract(epoch from (i.invoice_date::timestamptz - l.delivery_time)) / 86400.0)::numeric, 1)
        from public.loads l join public.invoices i on i.id = l.invoice_id
       where l.delivery_time is not null and i.invoice_date is not null
         and i.status <> 'void'
         and l.delivery_time >= now() - interval '90 days'
         and i.invoice_date::timestamptz >= l.delivery_time),
    -- #41/#42/#43 AR aging past 45/60/90 days (open balance by invoice age)
    'ar_over_45', coalesce((select sum(public.invoice_balance(i)) from public.invoices i
        where i.status = 'sent' and i.invoice_date < current_date - 45), 0),
    'ar_over_60', coalesce((select sum(public.invoice_balance(i)) from public.invoices i
        where i.status = 'sent' and i.invoice_date < current_date - 60), 0),
    'ar_over_90', coalesce((select sum(public.invoice_balance(i)) from public.invoices i
        where i.status = 'sent' and i.invoice_date < current_date - 90), 0),
    'as_of', now()
  );
  return out;
end;
$$;
revoke all on function public.finance_extras() from public, anon;
grant execute on function public.finance_extras() to authenticated, service_role;

-- Flip: new computations
update public.playbook_metrics set status='live', source='finance_extras().accessorial_revenue_90d', updated_at=now() where number = 15;
update public.playbook_metrics set status='live', source='finance_extras().detention_capture_rate_pct', updated_at=now() where number = 71;
update public.playbook_metrics set status='live', source='finance_extras().billing_lag_days', updated_at=now() where number = 75;
update public.playbook_metrics set status='live', source='finance_extras().ar_over_45', updated_at=now() where number = 41;
update public.playbook_metrics set status='live', source='finance_extras().ar_over_60', updated_at=now() where number = 42;
update public.playbook_metrics set status='live', source='finance_extras().ar_over_90', updated_at=now() where number = 43;
-- Flip: already-live computations that never got their pointer
update public.playbook_metrics set status='live', source='gl_balance_ratios().ebitda_12m', updated_at=now() where number = 3;
update public.playbook_metrics set status='live', source='gl_balance_ratios().ebitda_12m ÷ trailing-12m revenue (Board pack)', updated_at=now() where number = 4;
update public.playbook_metrics set status='live', source='gl_balance_ratios().quick_ratio', updated_at=now() where number = 55;

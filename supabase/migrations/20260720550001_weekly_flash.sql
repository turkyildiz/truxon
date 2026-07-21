-- Weekly Owner Flash — the playbook's cadence ("weekly ops/cash/safety flash")
-- as one composed RPC on the week standard (Mon–Sun via trux_week_*). Pure
-- composition of already-tested pieces: weekly_report totals for ops, invoice
-- movement + forecast for cash, the scorecard's safety/detention sections, and
-- the Sentinel open-finding counts. One call, the whole week on one page.

create or replace function public.weekly_flash(p_week_offset int default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  d date := current_date + (p_week_offset * 7);
  ws date := public.trux_week_start(d);
  we date := public.trux_week_end(d);
  v_score jsonb;
  v_collected numeric;
  v_invoiced numeric;
  v_ar numeric;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  v_score := public.company_scorecard(ws::timestamptz, (we + 1)::timestamptz);

  -- cash collected this week: native payments + observed QBO paid flips
  select coalesce(sum(ip.amount), 0) into v_collected
    from invoice_payments ip
   where ip.received_at >= ws and ip.received_at < we + 1;
  v_collected := v_collected + coalesce((
    select sum(coalesce(i.total, 0)) from invoices i
     where i.source = 'qbo' and i.paid_at >= ws and i.paid_at < we + 1), 0);

  select coalesce(sum(i.total), 0) into v_invoiced
    from invoices i
   where i.invoice_date >= ws and i.invoice_date < we + 1
     and i.status <> 'void';

  select coalesce(sum(
           case when i.source = 'qbo' then coalesce(i.qbo_balance, 0)
                else i.total - coalesce(p.paid, 0) end), 0) into v_ar
    from invoices i
    left join lateral (
      select sum(ip.amount) paid from invoice_payments ip where ip.invoice_id = i.id
    ) p on true
   where i.status = 'sent';

  return jsonb_build_object(
    'week', jsonb_build_object(
      'label', public.trux_week_label(d), 'start', ws, 'end', we,
      'number', public.trux_week_number(d), 'year', public.trux_week_year(d)),
    'ops', jsonb_build_object(
      'loads', v_score->'operations'->'loads',
      'total_miles', v_score->'operations'->'total_miles',
      'empty_miles', v_score->'operations'->'empty_miles',
      'on_time_pct', v_score->'operations'->'on_time_delivery_pct',
      'revenue', v_score->'financial'->'revenue',
      'net', v_score->'financial'->'net',
      'detention_hours', v_score->'detention'->'hours',
      'detention_billable', v_score->'detention'->'est_billable'),
    'cash', jsonb_build_object(
      'collected_this_week', round(v_collected, 2),
      'invoiced_this_week', round(v_invoiced, 2),
      'ar_outstanding', round(v_ar, 2)),
    'safety', v_score->'safety',
    'sentinel', jsonb_build_object(
      'open', (select count(*) from trux_insights where status <> 'resolved'),
      'critical', (select count(*) from trux_insights
                    where status <> 'resolved' and severity = 'critical')),
    'budget', v_score->'budget'
  );
end;
$$;
revoke all on function public.weekly_flash(int) from public, anon;
grant execute on function public.weekly_flash(int) to authenticated, service_role;

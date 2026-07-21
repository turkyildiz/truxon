-- Insurance economics (Northstar resurrection): premiums were ALREADY flowing
-- through the GL mirror (insurance accounts, ~$29k/mo) and claims are captured
-- on safety_events.claim_amount — the loss ratio just needed the join. Flips
-- #30 Insurance CPM, #84 Premium $, #687 Loss Ratio (was 'external'), #688
-- Open Claims. NOT flipped: per-line (AL/cargo/WC) splits — safety_events does
-- not distinguish insurance lines, so those stay needs_data instead of guessed.

create or replace function public.insurance_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_premium12 numeric;
  v_claims12 numeric;
  v_miles12 numeric;
  v_open_claims int;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(amount), 0) into v_premium12
  from gl_monthly
  where grp in ('expense', 'cogs') and account ~* 'insurance'
    and month >= date_trunc('month', now()) - interval '12 months';

  select coalesce(sum(claim_amount), 0),
         count(*) filter (where status = 'open' and claim_amount > 0)
  into v_claims12, v_open_claims
  from safety_events
  where event_date >= (now() - interval '12 months')::date;

  select coalesce(sum(coalesce(miles, 0) + coalesce(empty_miles, 0)), 0) into v_miles12
  from loads
  where status in ('delivered', 'completed', 'billed')
    and coalesce(delivery_time, updated_at) >= now() - interval '12 months';

  return jsonb_build_object(
    'premium_12m', round(v_premium12, 2),
    'premium_monthly_avg', round(v_premium12 / 12, 2),
    'claims_12m', round(v_claims12, 2),
    'loss_ratio_pct', case when v_premium12 > 0
                           then round(v_claims12 / v_premium12 * 100, 1) end,
    'insurance_cpm', case when v_miles12 > 0
                          then round(v_premium12 / v_miles12, 3) end,
    'miles_12m', round(v_miles12, 0),
    'open_claims', v_open_claims
  );
end;
$$;
revoke all on function public.insurance_snapshot() from public, anon;
grant execute on function public.insurance_snapshot() to authenticated, service_role;

-- nightly series: add the insurance prefix to the capture
create or replace function public.capture_metric_snapshots()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_count int := 0;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  insert into metric_snapshots (metric_key, captured_on, value)
  select mf.metric_key, current_date, mf.value
  from (
    select * from public.metric_flatten('scorecard7',
      public.company_scorecard(now() - interval '7 days', now()))
    union all
    select * from public.metric_flatten('scorecard30',
      public.company_scorecard(now() - interval '30 days', now()))
    union all
    select * from public.metric_flatten('ops7',
      public.fleet_ops_extras(now() - interval '7 days', now()))
    union all
    select * from public.metric_flatten('costbasis', public.fleet_cost_basis())
    union all
    select * from public.metric_flatten('cfo', public.gl_cfo_snapshot())
    union all
    select * from public.metric_flatten('balance', public.gl_balance_ratios())
    union all
    select * from public.metric_flatten('insurance', public.insurance_snapshot())
    union all
    select 'ar.over_45', coalesce(sum(
             case when i.source = 'qbo' then coalesce(i.qbo_balance, 0)
                  else i.total - coalesce(p.paid, 0) end), 0)
    from invoices i
    left join lateral (
      select sum(ip.amount) paid from invoice_payments ip where ip.invoice_id = i.id
    ) p on true
    where i.status = 'sent' and i.invoice_date < now() - interval '45 days'
  ) mf
  where mf.value is not null and abs(mf.value) < 1e13
  on conflict (metric_key, captured_on) do update set value = excluded.value;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.capture_metric_snapshots() from public, anon, authenticated;
grant execute on function public.capture_metric_snapshots() to service_role;

select public.capture_metric_snapshots();

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'insurance_snapshot() — GL-mirror premiums (~insurance accounts) vs safety_events claim_amount'
where number in (30, 84, 687, 688) and status <> 'live';

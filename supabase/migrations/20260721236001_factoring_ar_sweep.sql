-- Factoring A/R sweep (site audit 2026-07-21): once an invoice is FACTORED
-- (factored_at not null) its open balance is owed by the FACTOR, not the
-- broker. acct_summary/acct_aging/cashflow_forecast were fixed earlier;
-- this closes the remaining 9 places that still counted factored reserves
-- as customer receivables: ar_aging (also switched from face total to
-- invoice_balance — partially paid invoices were counted at full value),
-- collections_queue, slow_pay_risk, customer_exposure (credit guard),
-- customer_profile, weekly_flash (owner flash + digest), company_scorecard,
-- capture_metric_snapshots (ar.over_45/60 trend metrics), and the
-- sentinel_scan slow-pay finding. Each is the latest definition with the
-- factored_at guard added — no other logic changed.

-- ── ar_aging ──
create or replace function public.ar_aging()
returns table (
  customer_id bigint, company_name text, invoices int, outstanding numeric,
  d0_30 numeric, d31_60 numeric, d61_90 numeric, d90_plus numeric
)
language sql stable security definer set search_path = public
as $$
  with aged as (
    select i.customer_id, public.invoice_balance(i) as total,
           (now()::date - coalesce(i.due_date, i.invoice_date)::date) as age_days
      from public.invoices i
     where i.status = 'sent' and i.factored_at is null
  )
  select c.id, c.company_name, count(*)::int, sum(a.total),
         sum(a.total) filter (where a.age_days <= 30),
         sum(a.total) filter (where a.age_days between 31 and 60),
         sum(a.total) filter (where a.age_days between 61 and 90),
         sum(a.total) filter (where a.age_days > 90)
    from aged a join public.customers c on c.id = a.customer_id
   where public.my_role() in ('admin','accountant','dispatcher')
   group by c.id, c.company_name
   order by 4 desc;                               -- most outstanding first
$$;

-- ── collections_queue ──
create or replace function public.collections_queue()
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
    where i.status = 'sent' and i.factored_at is null and i.due_date < now()
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

-- ── slow_pay_risk ──
create or replace function public.slow_pay_risk()
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
          where i.status = 'sent' and i.factored_at is null
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

-- ── customer_exposure ──
create or replace function public.customer_exposure(p_customer_id bigint)
returns jsonb
language plpgsql security definer set search_path = public stable
as $$
declare
  v_ar numeric; v_unbilled numeric; v_open numeric;
  v_monthly numeric; v_days numeric; v_limit numeric; v_exposure numeric;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(public.invoice_balance(i)), 0) into v_ar
    from invoices i where i.customer_id = p_customer_id and i.status = 'sent' and i.factored_at is null;

  select coalesce(sum(l.rate), 0) into v_unbilled
    from loads l
   where l.customer_id = p_customer_id and l.status = 'completed' and l.invoice_id is null;

  select coalesce(sum(l.rate), 0) into v_open
    from loads l
   where l.customer_id = p_customer_id and l.status in ('pending', 'assigned', 'in_transit');

  select coalesce(sum(i.total), 0) / 6.0 into v_monthly
    from invoices i
   where i.customer_id = p_customer_id
     and i.status in ('sent', 'paid')
     and i.invoice_date >= now() - interval '6 months';

  select p.avg_days into v_days
    from public.customer_pay_profile() p where p.customer_id = p_customer_id;

  v_limit := greatest(1.5 * v_monthly, 5000);
  if coalesce(v_days, 0) > 90 then v_limit := v_limit / 2; end if;
  v_exposure := v_ar + v_unbilled + v_open;

  return jsonb_build_object(
    'open_ar', round(v_ar),
    'unbilled', round(v_unbilled),
    'open_loads', round(v_open),
    'exposure', round(v_exposure),
    'limit', round(v_limit),
    'avg_days_to_pay', v_days,
    'over_limit', v_exposure > v_limit,
    'rule', '1.5x avg monthly billed (6m), min $5k, halved when avg pay >90d');
end;
$$;

-- ── customer_profile ──
create or replace function public.customer_profile(p_customer_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_gl_rpm numeric;
  v_ident jsonb; v_totals jsonb; v_monthly jsonb; v_pay jsonb; v_open jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select to_jsonb(c) - 'created_at' into v_ident from customers c where c.id = p_customer_id;
  if v_ident is null then
    return jsonb_build_object('found', false);
  end if;

  v_gl_rpm := coalesce((public.fleet_cost_basis()->>'gl_all_in_rpm')::numeric,
                       (public.fleet_cost_basis()->>'breakeven_rpm')::numeric, 0);

  select jsonb_build_object(
      'loads_12m', count(*),
      'revenue_12m', round(coalesce(sum(rate), 0), 2),
      'rpm_12m', round(sum(rate) / nullif(sum(miles), 0), 2),
      'est_margin_12m', round(coalesce(sum(rate) - sum(miles + coalesce(empty_miles, 0)) * v_gl_rpm, 0), 2),
      'margin_pct_12m', round((sum(rate) - sum(miles + coalesce(empty_miles, 0)) * v_gl_rpm)
                              / nullif(sum(rate), 0) * 100, 1),
      'last_load', max(delivery_time)::date,
      'first_load', min(delivery_time)::date)
    into v_totals
    from loads
   where customer_id = p_customer_id and status in ('completed', 'billed')
     and delivery_time > now() - interval '12 months';

  select jsonb_agg(t order by t.month) into v_monthly from (
    select to_char(date_trunc('month', delivery_time), 'YYYY-MM') as month,
           count(*) as loads,
           round(sum(rate), 0) as revenue,
           round(sum(rate) / nullif(sum(miles), 0), 2) as rpm
      from loads
     where customer_id = p_customer_id and status in ('completed', 'billed')
       and delivery_time > now() - interval '12 months'
     group by 1) t;

  select jsonb_build_object(
      'avg_days_to_pay', (select p.avg_days from public.customer_pay_profile() p where p.customer_id = p_customer_id),
      'paid_invoices_12m', (select p.paid_count from public.customer_pay_profile() p where p.customer_id = p_customer_id),
      'open_outstanding', round(coalesce((
          select sum(public.invoice_balance(i)) from invoices i
           where i.customer_id = p_customer_id and i.status = 'sent' and i.factored_at is null), 0), 2),
      'past_due_outstanding', round(coalesce((
          select sum(public.invoice_balance(i)) from invoices i
           where i.customer_id = p_customer_id and i.status = 'sent' and i.factored_at is null and i.due_date < now()), 0), 2),
      'open_invoices', (select count(*) from invoices i
           where i.customer_id = p_customer_id and i.status = 'sent' and i.factored_at is null and public.invoice_balance(i) > 0))
    into v_pay;

  select jsonb_build_object(
      'open_loads', (select count(*) from loads
           where customer_id = p_customer_id and status in ('pending', 'assigned', 'in_transit', 'delivered')),
      'unbilled_completed', (select count(*) from loads
           where customer_id = p_customer_id and status = 'completed' and invoice_id is null),
      'documents', (select count(*) from documents d
           where (d.entity_type = 'customer' and d.entity_id = p_customer_id)
              or (d.entity_type = 'load' and d.entity_id in
                    (select id from loads where customer_id = p_customer_id))),
      'detention_hours_45d', round(coalesce((
          select sum(e.detention_min) from public.detention_events(45) e
           join loads l on l.id = e.load_id where l.customer_id = p_customer_id), 0) / 60.0, 1))
    into v_open;

  return jsonb_build_object(
    'found', true,
    'customer', v_ident,
    'all_in_rpm_basis', v_gl_rpm,
    'totals', v_totals,
    'monthly', coalesce(v_monthly, '[]'::jsonb),
    'pay', v_pay,
    'activity', v_open);
end;
$$;

-- ── weekly_flash ──
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
   where i.status = 'sent' and i.factored_at is null;

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

-- ── company_scorecard ──
create or replace function public.company_scorecard(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  win_days numeric := greatest(extract(epoch from (p_end - p_start)) / 86400.0, 1);
  weeks numeric := greatest(win_days / 7.0, 0.1);
  revenue numeric; loaded_mi numeric; total_mi numeric; empty_mi numeric; loads_n int;
  fuel numeric; tolls numeric; driver_pay numeric; maint numeric; truck_fixed numeric;
  gal numeric; active_trucks int; trailers_n int;
  ar_out numeric; billed numeric; voided numeric;
  top5 numeric; customers_n int; newlogo numeric;
  avg_tractor_age numeric; avg_trailer_age numeric; inv_cycle numeric;
  total_cost numeric;
  gl_income numeric; gl_costs numeric; gl_months int;
  -- newly-captured (Northstar night)
  det_events int; det_min numeric; det_pay numeric;
  s record; csa_alerts int; acc_n int; prev_n int; oos_n int;
  veh_conn int; gps_live int; drivers_tracked int; low_hos int;
  ot_meas int; ot_hit int;
  v_sales jsonb;
begin
  if public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(rate),0), coalesce(sum(miles),0), coalesce(sum(empty_miles),0), count(*)
    into revenue, loaded_mi, empty_mi, loads_n
    from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;
  total_mi := loaded_mi + empty_mi;

  select coalesce(sum(coalesce(net_of_discount,amount)),0), coalesce(sum(gallons),0) into fuel, gal
    from public.fuel_transactions where status <> 'Declined' and transaction_time >= p_start and transaction_time < p_end;
  select coalesce(sum(toll_charge),0) into tolls from public.toll_transactions
   where coalesce(post_date_time,exit_date_time) >= p_start and coalesce(post_date_time,exit_date_time) < p_end;
  select coalesce(sum(l.miles*d.pay_per_mile + case when d.empty_miles_paid then coalesce(l.empty_miles,0)*d.pay_per_empty_mile else 0 end),0)
    into driver_pay from public.loads l join public.drivers d on d.id=l.driver_id
   where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end;
  select coalesce(sum(cost),0) into maint from public.maintenance_records
   where date_completed >= p_start::date and date_completed < p_end::date;
  select coalesce(round(sum(monthly_cost)*(win_days/30.44),2),0), count(*) into truck_fixed, active_trucks
    from public.trucks where status <> 'retired';
  select count(*) into trailers_n from public.trailers where status <> 'retired';
  total_cost := fuel + tolls + driver_pay + maint + truck_fixed;

  -- The BOOKS' view of the same window (drift exam caught OR 26.7% vs the
  -- GL's 64-79%: fuel history starts 2026-07-01 and truck fixed costs are
  -- zero, so operational total_cost understates badly). When the GL covers
  -- the window, margins come from the GL; operational costs stay as the
  -- direct-cost detail.
  select coalesce(sum(amount) filter (where grp = 'income'), 0),
         coalesce(sum(amount) filter (where grp in ('cogs', 'expense', 'other_expense')), 0),
         count(distinct month)
    into gl_income, gl_costs, gl_months
    from gl_monthly
   where month >= date_trunc('month', p_start)::date
     and month < p_end::date
     and win_days >= 28;  -- GL is monthly-grained: for sub-month windows the
                          -- overlap would return whole-month totals (caught
                          -- live: W28 digest showed monthly net on weekly
                          -- revenue). Short windows keep the operational basis.

  -- AR / bad debt
  -- OUTSTANDING balance, not face total: QBO-mirror invoices carry factoring-fee
  -- residuals and partial payments; sum(total) overstated open AR ~3x (exam find).
  select coalesce(sum(public.invoice_balance(i)),0) into ar_out from public.invoices i where i.status='sent' and i.factored_at is null;
  select coalesce(sum(total),0) into billed from public.invoices where status in ('sent','paid') and invoice_date >= p_start and invoice_date < p_end;
  select coalesce(sum(total),0) into voided from public.invoices where status='void' and invoice_date >= p_start and invoice_date < p_end;

  -- customer concentration + new-logo (customers created in last 12 months)
  select coalesce(sum(rev),0) from (
    select l.customer_id, sum(l.rate) rev from public.loads l
     where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end
     group by l.customer_id order by rev desc limit 5) t into top5;
  select count(distinct customer_id) into customers_n from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;
  select coalesce(sum(l.rate),0) into newlogo from public.loads l join public.customers c on c.id=l.customer_id
   where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end
     and c.id in (select id from public.customers where created_at > now() - interval '12 months');

  -- fleet age (from year if present) + invoice cycle time
  select round(avg(extract(year from now()) - year),1) into avg_tractor_age from public.trucks where status<>'retired' and year is not null;
  select round(avg(extract(year from now()) - year),1) into avg_trailer_age from public.trailers where status<>'retired' and year is not null;
  select round(avg(extract(epoch from (i.invoice_date - l.delivery_time))/86400.0),1) into inv_cycle
    from public.loads l join public.invoices i on i.id = l.invoice_id
   where l.delivery_time >= p_start and l.delivery_time < p_end and l.delivery_time is not null;

  -- ===== NEWLY CAPTURED =====
  -- Detention (ELD dwell vs free time) over a trailing window matching the scorecard.
  select count(*), coalesce(sum(detention_min),0), coalesce(sum(est_pay),0)
    into det_events, det_min, det_pay
    from public.detention_events(greatest(ceil(win_days)::int, 1));

  -- Safety: latest FMCSA snapshot + CSA alerts + in-window safety events.
  select * into s from public.carrier_safety_snapshot order by snapshot_date desc limit 1;
  select count(*) filter (where alert) into csa_alerts from public.safety_csa;
  select count(*) filter (where event_type='accident'),
         count(*) filter (where event_type='accident' and preventable),
         count(*) filter (where out_of_service)
    into acc_n, prev_n, oos_n
    from public.safety_events where event_date >= p_start::date and event_date < p_end::date;

  -- Telematics/HOS: ELD connectivity + live GPS + drivers low on drive hours.
  select count(*) filter (where truck_id is not null) into veh_conn from public.eld_vehicles;
  select count(*) into gps_live from public.eld_vehicle_status where lat is not null and ts > now() - interval '2 hours';
  select count(*) filter (where drive_sec is not null),
         count(*) filter (where drive_sec is not null and drive_sec < 3600)
    into drivers_tracked, low_hos from public.eld_driver_status;

  -- On-time delivery: of in-window loads with an ELD arrival near the delivery
  -- stop, the share that arrived by the appointment (+2h grace).
  with arr as (
    select l.delivery_time,
           (select min(h.ts) from public.eld_location_history h
             where h.truck_id = l.truck_id
               and h.ts between l.delivery_time - interval '18 hours' and l.delivery_time + interval '18 hours'
               and public.trux_miles(l.delivery_lat, l.delivery_lon, h.lat, h.lng) <= 0.75) as eld_arr
      from public.loads l
     where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end
       and l.truck_id is not null and l.delivery_lat is not null and l.delivery_time is not null
  )
  select count(*) filter (where eld_arr is not null),
         count(*) filter (where eld_arr is not null and eld_arr <= delivery_time + interval '2 hours')
    into ot_meas, ot_hit from arr;

  v_sales := public.sales_pipeline(p_start, p_end);

  return jsonb_build_object(
    'window', jsonb_build_object('start', p_start, 'end', p_end, 'days', round(win_days,1)),
    'financial', jsonb_build_object(
      'revenue', round(revenue,2),
      'total_cost', round(total_cost,2),
      'net', case when gl_income > 0 then round(gl_income-gl_costs,2)
                  else round(revenue-total_cost,2) end,
      'operating_ratio_pct', case when gl_income > 0 then round(gl_costs/gl_income*100,1)
                                  when revenue>0 then round(total_cost/revenue*100,1) end,
      'net_margin_pct', case when gl_income > 0 then round((gl_income-gl_costs)/gl_income*100,1)
                             when revenue>0 then round((revenue-total_cost)/revenue*100,1) end,
      'margin_basis', case when gl_income > 0
                           then format('GL (books), %s calendar months overlapping window', gl_months)
                           else 'operational tables — fuel history starts 2026-07-01, treat as partial' end,
      'contribution_margin', round(revenue-(fuel+tolls+driver_pay),2),
      'revenue_per_total_mile', case when total_mi>0 then round(revenue/total_mi,2) end,
      'revenue_per_loaded_mile', case when loaded_mi>0 then round(revenue/loaded_mi,2) end,
      'cost_per_total_mile', case when total_mi>0 then round(total_cost/total_mi,2) end,
      'fuel_cost_per_mile', case when total_mi>0 then round(fuel/total_mi,3) end,
      'maintenance_cost_per_mile', case when total_mi>0 then round(maint/total_mi,3) end,
      'driver_pay_pct_revenue', case when revenue>0 then round(driver_pay/revenue*100,1) end,
      'ar_outstanding', round(ar_out,2),
      'dso_days', case when revenue>0 then round(ar_out/(revenue/win_days),1) end,
      'bad_debt_pct', case when billed>0 then round(voided/billed*100,2) end,
      'detention_billable', round(det_pay,2)),
    'operations', jsonb_build_object(
      'loads', loads_n,
      'total_miles', total_mi, 'loaded_miles', loaded_mi, 'empty_miles', empty_mi,
      'empty_mile_pct', case when total_mi>0 then round(empty_mi/total_mi*100,1) end,
      'loaded_ratio_pct', case when total_mi>0 then round(loaded_mi/total_mi*100,1) end,
      'miles_per_tractor_per_week', case when active_trucks>0 then round(total_mi/active_trucks/weeks,0) end,
      'loads_per_tractor_per_week', case when active_trucks>0 then round(loads_n::numeric/active_trucks/weeks,2) end,
      'avg_length_of_haul', case when loads_n>0 then round(loaded_mi/loads_n,0) end,
      'trailer_to_tractor_ratio', case when active_trucks>0 then round(trailers_n::numeric/active_trucks,2) end,
      'fleet_mpg', case when gal>0 then round(loaded_mi/gal,2) end,
      'on_time_delivery_pct', case when ot_meas>0 then round(ot_hit::numeric/ot_meas*100,1) end,
      'on_time_sample', ot_meas),
    'revenue', jsonb_build_object(
      'active_customers', customers_n,
      'avg_revenue_per_customer', case when customers_n>0 then round(revenue/customers_n,2) end,
      'top5_concentration_pct', case when revenue>0 then round(top5/revenue*100,1) end,
      'new_logo_revenue_pct', case when revenue>0 then round(newlogo/revenue*100,1) end,
      'rate_per_loaded_mile', case when loaded_mi>0 then round(revenue/loaded_mi,2) end),
    'sales', v_sales,
    'budget', (select jsonb_agg(to_jsonb(b)) from public.budget_variance(p_start, p_end) b),
    'insurance', public.insurance_snapshot(),
    'balance', public.gl_balance_ratios(),
    'safety', jsonb_build_object(
      'fmcsa_rating', case when s.safety_rating is null or s.safety_rating='' then 'Not rated' else public.fmcsa_rating_label(s.safety_rating) end,
      'allowed_to_operate', nullif(s.allowed_to_operate,''),
      'driver_oos_rate_pct', s.driver_oos_rate, 'driver_oos_national_pct', s.driver_oos_natl,
      'vehicle_oos_rate_pct', s.vehicle_oos_rate, 'vehicle_oos_national_pct', s.vehicle_oos_natl,
      'crashes_24mo', s.crash_total,
      'csa_basics_over_threshold', coalesce(csa_alerts,0),
      'accidents_in_window', coalesce(acc_n,0),
      'preventable_accidents_in_window', coalesce(prev_n,0),
      'out_of_service_events_in_window', coalesce(oos_n,0)),
    'detention', jsonb_build_object(
      'events', coalesce(det_events,0),
      'hours', round(coalesce(det_min,0)/60.0,1),
      'est_billable', round(coalesce(det_pay,0),2)),
    'telematics', jsonb_build_object(
      'eld_vehicles_connected', coalesce(veh_conn,0),
      'gps_live_2h', coalesce(gps_live,0),
      'drivers_hos_tracked', coalesce(drivers_tracked,0),
      'drivers_low_on_drive_hours', coalesce(low_hos,0),
      'idle_pct_30d', (public.idle_summary(30)->>'idle_pct')::numeric),
    'maintenance', jsonb_build_object(
      'avg_tractor_age_years', avg_tractor_age,
      'avg_trailer_age_years', avg_trailer_age,
      'maintenance_cost_per_mile', case when total_mi>0 then round(maint/total_mi,3) end),
    'systems', jsonb_build_object(
      'invoice_cycle_days', inv_cycle),
    'people', public.driver_turnover(p_start, p_end),
    'not_captured', jsonb_build_array(
      'telematics harsh-braking events'),
    'driver_nps', coalesce(
      (select to_jsonb(nps_row) from public.driver_nps_summary() nps_row
        order by nps_row.quarter desc limit 1),
      jsonb_build_object('status',
        'survey LIVE in the driver app since 2026-07-20 — no responses yet'))
  );
end;
$$;

-- ── capture_metric_snapshots ──
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
    select * from public.metric_flatten('mx30',
      public.maintenance_cpm(now() - interval '30 days', now()))
    union all
    select * from public.metric_flatten('safety30',
      public.safety_summary(now() - interval '30 days', now()))
    union all
    select * from public.metric_flatten('segments30',
      public.segment_economics(now() - interval '30 days', now()) -> 'fleet')
    union all
    select 'ar.over_45', coalesce(sum(
             case when i.source = 'qbo' then coalesce(i.qbo_balance, 0)
                  else i.total - coalesce(p.paid, 0) end), 0)
    from invoices i
    left join lateral (
      select sum(ip.amount) paid from invoice_payments ip where ip.invoice_id = i.id
    ) p on true
    where i.status = 'sent' and i.factored_at is null and i.invoice_date < now() - interval '45 days'
    union all
    select 'ar.over_60', coalesce(sum(
             case when i.source = 'qbo' then coalesce(i.qbo_balance, 0)
                  else i.total - coalesce(p.paid, 0) end), 0)
    from invoices i
    left join lateral (
      select sum(ip.amount) paid from invoice_payments ip where ip.invoice_id = i.id
    ) p on true
    where i.status = 'sent' and i.factored_at is null and i.invoice_date < now() - interval '60 days'
  ) mf
  where mf.value is not null and abs(mf.value) < 1e13
  on conflict (metric_key, captured_on) do update set value = excluded.value;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ── sentinel_scan ──
create or replace function public.sentinel_scan()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  fired int;
  resolved int;
  v_dso numeric;
begin
  if auth.role() <> 'service_role' and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  drop table if exists _findings;
  create temp table _findings (
    dedup_key text primary key, category text, severity text, title text,
    detail text, entity_type text, entity_id bigint
  ) on commit drop;

  -- ===== MONEY =====
  insert into _findings
  select 'toll_violation:'||t.id, 'money',
         case when t.toll_charge >= 50 then 'critical' else 'warn' end,
         'Toll violation — '||coalesce(nullif(t.toll_agency_name,''),'unknown agency'),
         'Violation toll $'||t.toll_charge||' on unit '||coalesce(nullif(t.vehicle_number,''),'?')
           ||coalesce(' ('||nullif(t.toll_agency_state,'')||')',''),
         'truck', t.truck_id
    from public.toll_transactions t
   where t.toll_category = 'Violation' and coalesce(t.post_date_time, t.exit_date_time) > now() - interval '7 days';

  insert into _findings
  select 'unprofitable_truck:'||bt.key_id, 'money', 'warn',
         'Truck '||bt.name||' is running at a loss this week',
         'Revenue $'||bt.revenue||' vs fuel $'||bt.fuel_cost||' — net after fuel $'||bt.net_after_fuel,
         'truck', bt.key_id
    from jsonb_to_recordset(public.weekly_report()->'by_truck')
      as bt(key_id bigint, name text, revenue numeric, fuel_cost numeric, net_after_fuel numeric)
   where bt.net_after_fuel < 0;

  -- Customer concentration: a single customer > 20% of trailing-90-day revenue
  -- (playbook flags >15% as a risk to watch).
  insert into _findings
  select 'concentration:'||c.customer_id, 'money',
         case when c.share >= 35 then 'critical' else 'warn' end,
         cu.company_name||' is '||c.share||'% of revenue',
         'Customer concentration risk — '||c.share||'% of the last 90 days'' revenue rides on one account',
         'customer', c.customer_id
    from (
      select l.customer_id,
             round(sum(l.rate) / nullif((select sum(rate) from public.loads
                where status in ('completed','billed') and delivery_time > now() - interval '90 days'),0) * 100, 1) as share
        from public.loads l
       where l.status in ('completed','billed') and l.delivery_time > now() - interval '90 days'
       group by l.customer_id
    ) c join public.customers cu on cu.id = c.customer_id
   where c.share >= 20;

  -- ===== CASH =====
  insert into _findings
  select 'ar_overdue:'||a.customer_id, 'cash',
         case when a.d90_plus > 0 then 'critical' else 'warn' end,
         a.company_name||' is overdue',
         '$'||(a.d61_90 + a.d90_plus)||' past 60 days'||coalesce(' ($'||nullif(a.d90_plus,0)||' past 90)',''),
         'customer', a.customer_id
    from public.ar_aging() a where (a.d61_90 + a.d90_plus) > 0;

  insert into _findings
  select 'uninvoiced:'||l.id, 'cash', 'warn',
         'Load '||l.load_number||' delivered but not invoiced',
         'Completed '||to_char(l.delivery_time,'Mon DD')||', $'||l.rate||' not yet on an invoice',
         'load', l.id
    from public.loads l
   where l.status = 'completed' and l.invoice_id is null and l.delivery_time < now() - interval '7 days';

  -- Missing PODs — one summary nudge (there can be 100+). Brokers won't pay
  -- without proof of delivery; call out how many already have a matching file in
  -- the PODs archive ready to attach from the load page.
  insert into _findings
  select 'missing_pods', 'cash',
         case when cnt.n >= 20 then 'critical' else 'warn' end,
         cnt.n||' delivered load'||case when cnt.n = 1 then '' else 's' end||' missing a POD',
         'Brokers won''t pay without proof of delivery'
           ||case when cnt.archived > 0
                  then ' — '||cnt.archived||' already have a matching file in the PODs archive, ready to attach'
                  else '' end,
         '', null
    from (
      select count(*)::int as n,
             count(*) filter (
               where public.pod_archive_candidate(coalesce(lm.reference_number,''),
                                                   coalesce(lm.pickup_number,''),
                                                   coalesce(lm.delivery_number,'')) is not null
             )::int as archived
        from public.loads_missing_pod(45) lm
    ) cnt
   where cnt.n > 0;

  -- Predictive slow-pay: this broker's own history says the invoice WILL land
  -- late. Early warning while a nudge can still move it. Auto-resolves on pay.
  select coalesce(round(avg(cpp.avg_days), 1), 30) into v_dso from public.customer_pay_profile() cpp;
  insert into _findings
  select 'slow_pay:'||r.invoice_id, 'cash', 'warn',
         r.customer||' will likely pay '||r.invoice_number||' late',
         '$'||round(r.outstanding, 2)||' open — '||r.customer||' averages '||round(r.avg_days)||' days to pay; predicts ~'
           ||r.predicted_days_late||' days past the '||to_char(r.due_date,'Mon DD')||' due date. Nudge now to protect cash flow.',
         'customer', r.customer_id
    from (
      select i.id as invoice_id,
             case when i.invoice_number like 'QBO-%'
                  then '#'||coalesce(nullif(i.qbo_doc_number,''), substring(i.invoice_number from 5))
                  else i.invoice_number end as invoice_number,
             c.company_name as customer, i.customer_id, i.total,
             round(case when i.source = 'qbo' and i.qbo_balance is not null then i.qbo_balance
                        else i.total - coalesce(pay.paid, 0) end, 2) as outstanding,
             coalesce(p.avg_days, v_dso) as avg_days,
             coalesce(i.due_date::date, i.invoice_date::date + 30) as due_date,
             greatest(0, (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int)
                         - coalesce(i.due_date::date, i.invoice_date::date + 30))::int as predicted_days_late
        from public.invoices i
        join public.customers c on c.id = i.customer_id
        left join (select * from public.customer_pay_profile()) p on p.customer_id = i.customer_id
        left join (select p2.invoice_id, sum(p2.amount) as paid
                     from public.invoice_payments p2 group by p2.invoice_id) pay on pay.invoice_id = i.id
       where i.status = 'sent' and i.factored_at is null
    ) r
   where r.predicted_days_late > 15
     and r.outstanding >= 1
     and not (r.outstanding <= 200 and r.outstanding <= 0.10 * r.total);


  -- Detention: ELD dwell says the truck sat past free time and the broker owes.
  -- Fires per stop; ages out of the 14-day window (bill it before then).
  insert into _findings
  select 'detention:'||d.load_id||':'||d.stop_type, 'cash',
         case when d.est_pay >= 300 then 'critical' else 'warn' end,
         'Detention billable — load '||d.load_number||' ('||round(d.detention_min/60.0,1)||'h over free at '||d.stop_type||')',
         'Truck sat '||round(d.dwell_min/60.0,1)||'h at the '||d.stop_type
           ||coalesce(' in '||nullif(d.stop_state,''),'')||' — ~$'||d.est_pay||' detention owed by '||d.customer
           ||'. Bill it back (confirm the broker''s rate-con terms).',
         'load', d.load_id
    from public.detention_events(14) d
   where d.est_pay >= 50;

  -- ===== OPS =====
  insert into _findings
  select 'late_load:'||l.id, 'ops',
         case when l.delivery_time < now() - interval '12 hours' then 'critical' else 'warn' end,
         'Load '||l.load_number||' is late',
         'Delivery was due '||to_char(l.delivery_time,'Mon DD HH24:MI')||' — still '||l.status,
         'load', l.id
    from public.loads l
   where l.status in ('assigned','in_transit') and l.delivery_time < now();

  insert into _findings
  select 'gps_stale:'||dd.driver_id, 'ops', 'warn',
         'No GPS from '||d.full_name,
         'On duty since '||to_char(dd.on_duty_since,'HH24:MI')||' but no position in 30+ min',
         'driver', dd.driver_id
    from public.driver_duty dd join public.drivers d on d.id = dd.driver_id
   where dd.is_on_duty
     and not exists (select 1 from public.vehicle_position_current v
                      where v.driver_id = dd.driver_id and v.recorded_at > now() - interval '30 minutes');

  -- ===== COMPLIANCE =====
  insert into _findings
  select 'license_exp:'||d.id, 'compliance',
         case when d.license_expiration < now()::date then 'critical' else 'warn' end,
         'License '||case when d.license_expiration < now()::date then 'EXPIRED' else 'expiring' end||' — '||d.full_name,
         'CDL expires '||to_char(d.license_expiration,'Mon DD, YYYY'),
         'driver', d.id
    from public.drivers d
   where d.status = 'active' and d.license_expiration is not null and d.license_expiration < now()::date + 30;

  insert into _findings
  select 'plate_exp:'||t.id, 'compliance',
         case when t.plate_expiry < now()::date then 'critical' else 'warn' end,
         'Registration '||case when t.plate_expiry < now()::date then 'EXPIRED' else 'expiring' end||' — truck '||t.unit_number,
         'Plate '||coalesce(nullif(t.plate_number,''),'?')||' expires '||to_char(t.plate_expiry,'Mon DD, YYYY'),
         'truck', t.id
    from public.trucks t
   where t.status <> 'retired' and t.plate_expiry is not null and t.plate_expiry < now()::date + 30;

  -- Trailer registration parity with trucks.
  insert into _findings
  select 'trailer_plate_exp:'||t.id, 'compliance',
         case when t.plate_expiry < now()::date then 'critical' else 'warn' end,
         'Registration '||case when t.plate_expiry < now()::date then 'EXPIRED' else 'expiring' end||' — trailer '||t.unit_number,
         'Plate '||coalesce(nullif(t.plate_number,''),'?')||' expires '||to_char(t.plate_expiry,'Mon DD, YYYY'),
         'trailer', t.id
    from public.trailers t
   where t.status <> 'retired' and t.plate_expiry is not null and t.plate_expiry < now()::date + 30;

  -- ===== SAFETY =====
  insert into _findings
  select 'accident:'||e.id, 'compliance',
         case when e.severity = 'critical' or e.preventable then 'critical' else 'warn' end,
         'Accident logged'||case when e.preventable then ' (PREVENTABLE)' else '' end
           ||coalesce(' — '||nullif((select full_name from public.drivers where id=e.driver_id),''),''),
         to_char(e.event_date,'Mon DD')||coalesce(' at '||nullif(e.location,''),'')||coalesce(' — '||nullif(e.description,''),''),
         'driver', e.driver_id
    from public.safety_events e
   where e.event_type = 'accident' and e.event_date > now()::date - 30;

  insert into _findings
  select 'oos:'||e.id, 'compliance', 'warn',
         'Out-of-service event',
         to_char(e.event_date,'Mon DD')||coalesce(' — '||nullif(e.description,''),'')
           ||coalesce(' (unit '||nullif((select unit_number from public.trucks where id=e.truck_id),'')||')',''),
         'truck', e.truck_id
    from public.safety_events e
   where e.out_of_service and e.event_date > now()::date - 30;

  insert into _findings
  select 'safety_open_critical:'||e.id, 'compliance', 'critical',
         'Open critical '||e.event_type,
         coalesce(nullif(e.description,''),initcap(e.event_type))||
           case when e.claim_amount > 0 then ' — $'||e.claim_amount||' exposure' else '' end,
         'driver', e.driver_id
    from public.safety_events e
   where e.severity = 'critical' and e.status = 'open';

  insert into _findings
  select 'csa_alert:'||s.basic, 'compliance', 'warn',
         'CSA alert — '||replace(initcap(replace(s.basic,'_',' ')),' ',' '),
         'BASIC '||s.basic||' at '||coalesce(s.percentile::text,'?')||' percentile (over threshold)',
         '', null
    from public.safety_csa s where s.alert;

  -- FMCSA safety rating lost, or authority pulled — existential, fires critical.
  insert into _findings
  select 'fmcsa_rating', 'compliance', 'critical',
         case when s.allowed_to_operate = 'N' then 'FMCSA — NOT authorized to operate'
              else 'FMCSA safety rating: '||public.fmcsa_rating_label(s.safety_rating) end,
         'As of '||to_char(s.snapshot_date,'Mon DD, YYYY')
           ||' — driver OOS '||coalesce(round(s.driver_oos_rate,1)::text,'?')||'%'
           ||', vehicle OOS '||coalesce(round(s.vehicle_oos_rate,1)::text,'?')||'%',
         '', null
    from (select * from public.carrier_safety_snapshot order by snapshot_date desc limit 1) s
   where s.allowed_to_operate = 'N' or upper(s.safety_rating) in ('C','U');

  -- ===== MAINTENANCE =====
  insert into _findings
  select 'pm_overdue:'||d.equipment_type||':'||d.unit_id||':'||d.program_id, 'maintenance',
         case when d.service_type = 'dot_inspection' then 'critical' else 'warn' end,
         d.program_name||' overdue — '||d.unit_number,
         case when d.miles_remaining is not null and d.miles_remaining < 0 then 'Over by '||abs(d.miles_remaining)||' mi'
              when d.days_remaining  is not null and d.days_remaining  < 0 then 'Over by '||abs(d.days_remaining)||' days'
              else 'Due now' end,
         d.equipment_type, d.unit_id
    from public.maintenance_due() d
   where d.due_status = 'overdue';

  insert into _findings
  select 'repeat_repair:'||m.truck_id, 'maintenance', 'warn',
         'Unit '||t.unit_number||' — '||count(*)||' unplanned repairs in 30 days',
         'Repeat breakdowns totalling $'||round(sum(m.cost),2)||' reactive spend — investigate root cause',
         'truck', m.truck_id
    from public.maintenance_records m join public.trucks t on t.id = m.truck_id
   where m.status = 'completed' and not m.is_planned and m.truck_id is not null
     and m.date_completed > current_date - 30
   group by m.truck_id, t.unit_number
  having count(*) >= 3;

  insert into _findings
  select 'wo_stale:'||m.id, 'maintenance', 'warn',
         'Work order open '||(current_date - m.created_at::date)||' days',
         coalesce(nullif(m.description,''),'(no description)')||' — unit '
           ||coalesce((select unit_number from public.trucks where id=m.truck_id),
                      (select unit_number from public.trailers where id=m.trailer_id),'?'),
         m.equipment_type::text, coalesce(m.truck_id, m.trailer_id)
    from public.maintenance_records m
   where m.status in ('scheduled','in_progress') and m.created_at < now() - interval '10 days';

  -- ===== DATA HYGIENE =====
  -- a load still "moving" a week past its delivery appointment was almost
  -- certainly delivered and never closed out (the loads #2/#11 pattern)
  insert into _findings
  select 'stale_transit:'||l.id, 'data', 'warn',
         'Load '||l.load_number||' still '||l.status||' '
           ||(current_date - coalesce(l.delivery_time, l.pickup_time)::date)||' days after its appointment',
         'Assigned '||coalesce((select d.full_name from public.drivers d where d.id = l.driver_id), 'no driver')
           ||' / '||coalesce((select t.unit_number from public.trucks t where t.id = l.truck_id), 'no truck')
           ||' — mark delivered/cancelled so dispatch, billing and forecasts see reality',
         'load', l.id
    from public.loads l
   where l.status in ('assigned', 'in_transit')
     and coalesce(l.delivery_time, l.pickup_time) < now() - interval '7 days';

  -- one driver on two active loads blocks dispatch and poisons utilization
  insert into _findings
  select 'double_booked:'||d.id, 'data', 'critical',
         d.full_name||' is on '||count(*)||' active loads at once',
         string_agg(l.load_number, ', ' order by l.id)
           ||' — resolve which is real; stale ones should be delivered/cancelled',
         'driver', d.id
    from public.loads l join public.drivers d on d.id = l.driver_id
   where l.status in ('assigned', 'in_transit')
   group by d.id, d.full_name
  having count(*) > 1;

  -- a delivered load with no POD/BOL after 14 days cannot be invoiced cleanly
  insert into _findings
  select 'missing_pod:'||l.id, 'data', 'warn',
         'Load '||l.load_number||' has no POD '
           ||(current_date - coalesce(l.delivery_time, l.updated_at)::date)||' days after delivery',
         'Customer '||coalesce((select c.company_name from public.customers c where c.id = l.customer_id), '?')
           ||' — chase the paperwork or billing stalls (the dispatch miner is also searching the inbox)',
         'load', l.id
    from public.loads l
   where l.status in ('delivered', 'completed')
     and coalesce(l.delivery_time, l.updated_at) < now() - interval '14 days'
     and coalesce(l.delivery_time, l.updated_at) > now() - interval '60 days'
     and not exists (select 1 from public.documents doc
                      where doc.entity_type = 'load' and doc.entity_id = l.id
                        and doc.doc_type in ('pod', 'bol', 'receipt', 'scale'));

  -- ===== R3 #4: trend breaks — no red metric without an action =====
  -- Any nightly-snapshotted series that lurched >=25% week-over-week gets a
  -- finding. Auto-resolve clears it once the series settles; dedup keeps one
  -- finding per series. wow_pct is null when the prior week was 0 — skip
  -- those (a series being born is not an anomaly).
  insert into _findings
  select 'trend:'||t.metric_key, 'ops', 'warn',
         'Trend break — '||t.metric_key,
         t.metric_key||' moved '||round(t.wow_pct, 1)||'% WoW (now '||round(t.latest, 1)
           ||', 13-week slope '||coalesce(round(t.slope_13w, 2)::text, '?')
           ||'). The playbook rule: no red metric without an action.',
         '', null
    from public.metric_trends(null) t
   where t.points >= 4
     and t.wow_pct is not null
     and abs(t.wow_pct) >= 25;


  -- ===== FUEL THEFT / CARD MISUSE (added 2026-07-21) =====
  -- 1) Product mismatch: gasoline/ethanol bought on a DIESEL truck's card. A
  -- diesel truck physically can't burn these — it's a second vehicle or resale.
  insert into _findings
  select 'fuel_product:'||f.truck_id, 'money', 'critical',
         'Non-diesel fuel on truck '||coalesce(t.unit_number,'?')||' — card misuse?',
         count(*)||' non-diesel fill(s) in 30d ($'||round(sum(f.amount))::text||'): '
           ||string_agg(distinct f.fuel_type, ', ')||'. A diesel truck can''t use these.',
         'truck', f.truck_id
    from public.fuel_transactions f
    join public.trucks t on t.id = f.truck_id
   where lower(coalesce(f.fuel_type,'')) ~ '(unleaded|ethanol|gasoline|premium|regular|e85|midgrade)'
     and coalesce(f.gallons,0) > 3
     and f.transaction_time > now() - interval '30 days'
   group by f.truck_id, t.unit_number;

  -- 2) Cash advances / non-fuel charges (0-gallon spend). Fuel cards aren't ATMs.
  insert into _findings
  select 'fuel_cash:'||x.truck_id, 'money',
         case when x.nonfuel >= 2000 then 'critical' else 'warn' end,
         'High non-fuel spend on truck '||coalesce(t.unit_number,'?')||'''s fuel card',
         '$'||round(x.nonfuel)::text||' in '||x.n||' cash-advance/fee charge(s) (0 gal) in 30d'
           ||case when x.nonfuel > x.diesel then ' — MORE than its $'||round(x.diesel)::text||' of actual diesel' else '' end,
         'truck', x.truck_id
    from (
      select f.truck_id,
             coalesce(sum(f.amount) filter (where coalesce(f.gallons,0)=0 and f.amount>0),0) as nonfuel,
             count(*)              filter (where coalesce(f.gallons,0)=0 and f.amount>0)     as n,
             coalesce(sum(f.amount) filter (where coalesce(f.gallons,0)>0),0)                as diesel
        from public.fuel_transactions f
       where f.transaction_time > now() - interval '30 days'
       group by f.truck_id
    ) x
    join public.trucks t on t.id = x.truck_id
   where x.nonfuel >= 500;

  -- 3) Tank overflow: a single fill bigger than any one truck's tanks (dual
  -- tanks ~ up to ~250 gal, so 200+ in ONE transaction means a second vehicle).
  insert into _findings
  select 'fuel_overflow:'||f.id, 'money', 'critical',
         'Oversized single fuel fill — truck '||coalesce(t.unit_number,'?'),
         round(f.gallons)::text||' gal in ONE transaction '||to_char(f.transaction_time,'Mon DD')
           ||coalesce(' at '||nullif(f.merchant_city,''),'')||' — exceeds a single truck''s tank.',
         'truck', f.truck_id
    from public.fuel_transactions f
    join public.trucks t on t.id = f.truck_id
   where f.gallons > 200 and f.transaction_time > now() - interval '30 days';

  -- (A "rapid re-fuel" check was evaluated and dropped: on this fuel-card data
  --  it fired almost entirely on single stops split into two lines — a big fill
  --  plus a small top-off/DEF minutes apart at the SAME station — i.e. noise, not
  --  theft. Product-mismatch + cash-advance + overflow + the Tier-2 recon below
  --  carry the real signal without the false positives.)

  -- 4) TIER 2 — fuel-vs-miles reconciliation. Miles = LOADED (dispatch) + EMPTY
  -- (deadhead), so a truck that deadheads a lot is not unfairly flagged. Expected
  -- gallons at 6.5 MPG vs actually purchased; a truck buying materially MORE than
  -- its miles justify is diverting fuel. Guarded on enough miles+gallons, so it
  -- stays quiet until fuel-card capture is reasonably complete (no false alarms).
  insert into _findings
  with mi as (
    select l.truck_id,
           sum(coalesce(l.miles,0) + coalesce(l.empty_miles,0)) as total_miles,
           sum(coalesce(l.empty_miles,0)) as deadhead
      from public.loads l
     where l.status in ('completed','billed')
       and l.delivery_time > now() - interval '45 days'
       and l.truck_id is not null
     group by l.truck_id
  ), fu as (
    select f.truck_id, sum(coalesce(f.gallons,0)) as gal
      from public.fuel_transactions f
     where coalesce(f.gallons,0) > 0 and f.transaction_time > now() - interval '45 days'
     group by f.truck_id
  )
  select 'fuel_recon:'||mi.truck_id, 'money', 'warn',
         'Truck '||coalesce(t.unit_number,'?')||' bought more fuel than its miles justify',
         'Drove '||mi.total_miles::text||' mi (incl '||mi.deadhead::text||' deadhead) in 45d -> ~'
           ||round(mi.total_miles/6.5)::text||' gal expected at 6.5 MPG, but purchased '||round(fu.gal)::text
           ||' gal ('||round((fu.gal/nullif(mi.total_miles/6.5,0)-1)*100)::text||'% over). Possible diversion.',
         'truck', mi.truck_id
    from mi
    join fu on fu.truck_id = mi.truck_id
    join public.trucks t on t.id = mi.truck_id
   where mi.total_miles >= 2000 and fu.gal >= 100
     and fu.gal >= (mi.total_miles/6.5) * 1.25;

  -- ===== upsert + auto-resolve =====
  insert into public.trux_insights (dedup_key, category, severity, title, detail, entity_type, entity_id)
  select dedup_key, category, severity, title, detail, entity_type, entity_id from _findings
  on conflict (dedup_key) do update set
    severity = excluded.severity, title = excluded.title, detail = excluded.detail, last_seen = now(),
    status = case when public.trux_insights.status = 'resolved' then 'open' else public.trux_insights.status end,
    resolved_at = case when public.trux_insights.status = 'resolved' then null else public.trux_insights.resolved_at end;
  get diagnostics fired = row_count;

  update public.trux_insights set status = 'resolved', resolved_at = now()
   where status <> 'resolved' and dedup_key not in (select dedup_key from _findings);
  get diagnostics resolved = row_count;

  return jsonb_build_object(
    'fired', fired, 'resolved', resolved,
    'open', (select count(*) from public.trux_insights where status <> 'resolved'),
    'critical', (select count(*) from public.trux_insights where status <> 'resolved' and severity = 'critical'));
end;
$$;


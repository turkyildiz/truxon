-- Sweep: convert fragile negative service-role gates to positive form.
-- Old idiom:  if auth.role() <> 'service_role' and <role check fails> then raise
--   -> NULL auth.role() (direct superuser SQL) made the condition NULL and the gate
--      silently passed. Not exploitable via PostgREST (role claim always set), but fragile.
-- New idiom:  if not (coalesce(auth.role(), '') = 'service_role' or <role check passes>) then raise
-- Each function below is redefined whole from its latest lineage (canonical pg_get_functiondef
-- after a clean reset), with only the gate expression(s) changed.

-- bless_security_baseline: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.bless_security_baseline()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare v_added int; v_removed int;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') = 'admin') then
    raise exception 'Not enough permissions';
  end if;
  select count(*) into v_added   from app_private.security_posture() p
   where not exists (select 1 from app_private.security_baseline b where b.kind=p.kind and b.item=p.item);
  select count(*) into v_removed from app_private.security_baseline b
   where not exists (select 1 from app_private.security_posture() p where p.kind=b.kind and p.item=b.item);
  delete from app_private.security_baseline;
  insert into app_private.security_baseline select kind, item from app_private.security_posture();
  perform app_private.audit('security_baseline_blessed', case when v_added>0 then 'warn' else 'info' end,
    jsonb_build_object('added', v_added, 'removed', v_removed));
  return jsonb_build_object('blessed', true, 'newly_added', v_added, 'removed', v_removed);
end;
$function$;

-- cashflow_forecast: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.cashflow_forecast(p_weeks integer DEFAULT 8)
 RETURNS TABLE(week_start date, week_number integer, week_label text, expected_in numeric, expected_out numeric, net numeric, cumulative_net numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_dso numeric;
  v_fuel_wk numeric;
  v_fixed_wk numeric;
  v_driver_wk numeric;
  v_toll_wk numeric;
  v_maint_wk numeric;
  v_out_wk numeric;
  v_adv_rate numeric;
  v_rev_wk numeric;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') in ('admin', 'accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(round(avg(cpp.avg_days), 1), 30) into v_dso from public.customer_pay_profile() cpp;

  -- observed factoring advance rate (advanced / total across factored invoices)
  select coalesce(
           round(sum(i.total - case when i.status = 'sent' then public.invoice_balance(i) else 0 end)
                 / nullif(sum(i.total), 0), 4),
           0.90)
    into v_adv_rate
    from public.invoices i where i.factored_at is not null;

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

  -- trailing 8-week delivered-revenue run rate (mirrors the cost run rate)
  select coalesce(sum(l.rate), 0) / 8.0 into v_rev_wk
    from public.loads l
   where l.status in ('completed', 'billed') and l.delivery_time > now() - interval '56 days';

  return query
  with weeks as (
    select public.trux_week_start(current_date) + (g * 7) as ws
    from generate_series(0, greatest(p_weeks, 1) - 1) g
  ),
  prof as (select * from public.customer_pay_profile()),
  pay as (select p2.invoice_id, sum(p2.amount) as paid from public.invoice_payments p2 group by p2.invoice_id),
  -- open invoices at their OUTSTANDING amount (for factored ones that IS the
  -- reserve), landed at the broker's predicted pay week
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
  -- delivered-but-unbilled loads: the factoring ADVANCE arrives days after
  -- invoicing (~3d to invoice + ~2d funding), the RESERVE at broker pay lag
  unbilled_in as (
    select ws, sum(amt) as amt from (
      select public.trux_week_start(greatest(l.delivery_time::date + 5, current_date)) as ws,
             l.rate * v_adv_rate as amt
        from public.loads l
       where l.status = 'completed' and l.invoice_id is null and l.delivery_time is not null
      union all
      select public.trux_week_start(
               greatest(l.delivery_time::date + 3 + coalesce(p.avg_days, v_dso)::int, current_date)) as ws,
             l.rate * (1 - v_adv_rate) as amt
        from public.loads l left join prof p on p.customer_id = l.customer_id
       where l.status = 'completed' and l.invoice_id is null and l.delivery_time is not null
    ) u group by 1
  )
  select w.ws,
         public.trux_week_number(w.ws),
         public.trux_week_label(w.ws),
         round(coalesce(ii.amt, 0) + coalesce(ui.amt, 0)
               -- future hauling run-rate x advance rate, from the 2nd week on
               -- (this week's cash from this week's loads is mostly next week's)
               + case when w.ws > public.trux_week_start(current_date)
                      then v_rev_wk * v_adv_rate else 0 end, 2) as expected_in,
         v_out_wk as expected_out,
         round(coalesce(ii.amt, 0) + coalesce(ui.amt, 0)
               + case when w.ws > public.trux_week_start(current_date)
                      then v_rev_wk * v_adv_rate else 0 end - v_out_wk, 2) as net,
         round(sum(coalesce(ii.amt, 0) + coalesce(ui.amt, 0)
               + case when w.ws > public.trux_week_start(current_date)
                      then v_rev_wk * v_adv_rate else 0 end - v_out_wk)
                 over (order by w.ws rows between unbounded preceding and current row), 2) as cumulative_net
  from weeks w
  left join inv_in ii on ii.ws = w.ws
  left join unbilled_in ui on ui.ws = w.ws
  order by w.ws;
end;
$function$;

-- credit_memo_summary: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.credit_memo_summary(p_months integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_since date := date_trunc('month', current_date) - make_interval(months => p_months);
  v_cm numeric;
  v_n int;
  v_inv numeric;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select count(*), coalesce(sum(total), 0) into v_n, v_cm
    from qbo_credit_memos where txn_date >= v_since;
  select coalesce(sum(total), 0) into v_inv
    from invoices where status <> 'void' and invoice_date >= v_since;
  return jsonb_build_object(
    'months', p_months,
    'credit_memos', v_n,
    'credit_memo_total', round(v_cm, 2),
    'invoiced_total', round(v_inv, 2),
    'credit_memo_rate_pct', round(v_cm / nullif(v_inv, 0) * 100, 2),
    'invoice_accuracy_pct', round(100 - coalesce(v_cm / nullif(v_inv, 0) * 100, 0), 2),
    'recent', coalesce((select jsonb_agg(jsonb_build_object(
        'doc', m.doc_number, 'date', m.txn_date, 'total', m.total,
        'customer', c.company_name, 'memo', m.memo) order by m.txn_date desc)
      from (select * from qbo_credit_memos order by txn_date desc limit 10) m
      left join customers c on c.qbo_id = m.customer_qbo_id), '[]'::jsonb),
    'as_of', now());
end;
$function$;

-- detention_events: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.detention_events(p_days integer DEFAULT 45, p_free_min integer DEFAULT 120, p_rate numeric DEFAULT 50, p_radius_mi numeric DEFAULT 0.75)
 RETURNS TABLE(load_id bigint, load_number text, customer text, stop_type text, stop_state text, appointment timestamp with time zone, arrival timestamp with time zone, departure timestamp with time zone, dwell_min integer, free_min integer, detention_min integer, est_pay numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin', 'dispatcher', 'accountant')) then
    raise exception 'Not enough permissions';
  end if;
  return query
  with stops as (
    select l.id as load_id, l.load_number, c.company_name as customer, 'pickup'::text as stop_type,
           l.pickup_state as stop_state, l.pickup_time as appt, l.pickup_lat as lat, l.pickup_lon as lon, l.truck_id
      from public.loads l join public.customers c on c.id = l.customer_id
     where l.truck_id is not null and l.pickup_lat is not null and l.pickup_time is not null
       and l.delivery_time > now() - make_interval(days => p_days)
    union all
    select l.id, l.load_number, c.company_name, 'delivery',
           l.delivery_state, l.delivery_time, l.delivery_lat, l.delivery_lon, l.truck_id
      from public.loads l join public.customers c on c.id = l.customer_id
     where l.truck_id is not null and l.delivery_lat is not null and l.delivery_time is not null
       and l.delivery_time > now() - make_interval(days => p_days)
  ),
  dwell as (
    select s.*,
           (select min(h.ts) from public.eld_location_history h
             where h.truck_id = s.truck_id
               and h.ts between s.appt - interval '18 hours' and s.appt + interval '18 hours'
               and public.trux_miles(s.lat, s.lon, h.lat, h.lng) <= p_radius_mi) as arr,
           (select max(h.ts) from public.eld_location_history h
             where h.truck_id = s.truck_id
               and h.ts between s.appt - interval '18 hours' and s.appt + interval '18 hours'
               and public.trux_miles(s.lat, s.lon, h.lat, h.lng) <= p_radius_mi) as dep
      from stops s
  )
  select d.load_id, d.load_number, d.customer, d.stop_type, d.stop_state, d.appt, d.arr, d.dep,
         (extract(epoch from (d.dep - d.arr)) / 60)::int as dwell_min,
         p_free_min,
         greatest(0, (extract(epoch from (d.dep - d.arr)) / 60) - p_free_min)::int as detention_min,
         round(greatest(0, (extract(epoch from (d.dep - d.arr)) / 60) - p_free_min) / 60.0 * p_rate, 2) as est_pay
    from dwell d
   where d.arr is not null and d.dep is not null
     and (extract(epoch from (d.dep - d.arr)) / 60) > p_free_min
   order by detention_min desc;
end;
$function$;

-- dot_audit_pack: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.dot_audit_pack()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  return jsonb_build_object(
    'drivers_active', (select count(*) from drivers where status = 'active'),
    'cdl_on_file', (select count(*) from drivers where status = 'active'
                     and coalesce(license_number,'') <> ''),
    'cdl_expired', (select coalesce(jsonb_agg(jsonb_build_object('driver', full_name, 'expired', license_expiration)), '[]'::jsonb)
                     from drivers where status = 'active' and license_expiration < current_date),
    'cdl_expiring_60d', (select coalesce(jsonb_agg(jsonb_build_object('driver', full_name, 'expires', license_expiration)), '[]'::jsonb)
                          from drivers where status = 'active'
                            and license_expiration between current_date and current_date + 60),
    'medcard_on_file', (select count(*) from drivers where status = 'active' and medical_card_expiry is not null),
    'medcard_expired', (select coalesce(jsonb_agg(jsonb_build_object('driver', full_name, 'expired', medical_card_expiry)), '[]'::jsonb)
                         from drivers where status = 'active' and medical_card_expiry < current_date),
    'mvr_reviewed_12m', (select count(distinct e.driver_id) from driver_compliance_events e
                          join drivers d on d.id = e.driver_id and d.status = 'active'
                         where e.kind = 'mvr_review' and e.occurred_on > current_date - 365),
    'clearinghouse_12m', (select count(distinct e.driver_id) from driver_compliance_events e
                           join drivers d on d.id = e.driver_id and d.status = 'active'
                          where e.kind = 'clearinghouse_query' and e.occurred_on > current_date - 365),
    'drug_pool_enrolled', (select count(*) from drivers where status = 'active' and drug_pool_enrolled_on is not null),
    'dqf_complete', (public.driver_qual_files()->>'complete_count')::int,
    'trucks_active', (select count(*) from trucks where status <> 'retired'),
    'plates_expired', (select coalesce(jsonb_agg(jsonb_build_object('unit', unit_number, 'expired', plate_expiry)), '[]'::jsonb)
                        from trucks where status <> 'retired' and plate_expiry < current_date),
    'annual_inspection_current', (
      select count(distinct t.id) from trucks t
       where t.status <> 'retired' and exists (
         select 1 from maintenance_records m
          where m.truck_id = t.id and m.status = 'completed'
            and (m.service_type::text = 'dot_inspection'
                 or m.service_type::text ilike '%annual%' or m.service_type::text ilike '%dot inspect%'
                 or m.description ilike '%annual inspection%' or m.description ilike '%dot inspection%')
            and m.date_completed > current_date - 365)),
    'eld_reporting_7d', (select count(distinct truck_id) from eld_daily_miles where day > current_date - 7),
    'dvir_drivers_30d', (select count(distinct driver_id) from dvir where created_at > now() - interval '30 days'),
    'safety_events_365d', (select count(*) from safety_events where created_at > now() - interval '365 days'),
    'not_tracked', jsonb_build_array(
      'previous-employer safety performance history (391.23 investigations)',
      'full Clearinghouse query RESULTS (only the query date is logged)'),
    'as_of', now());
end;
$function$;

-- factoring_cost_summary: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.factoring_cost_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_face numeric;
  v_fees numeric;
  v_rate numeric;
  v_book_days numeric;
  v_days_gained numeric;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;

  select round(sum(i.total), 2), round(sum(i.factoring_fee), 2)
    into v_face, v_fees
    from invoices i
   where i.factored_at is not null and coalesce(i.factoring_fee, 0) > 0 and i.total > 0;
  v_rate := round(v_fees / nullif(v_face, 0) * 100, 2);

  select round(avg(cpp.avg_days), 0) into v_book_days from public.customer_pay_profile() cpp;
  -- Denim advances land ~2 days after invoicing
  v_days_gained := greatest(coalesce(v_book_days, 0) - 2, 0);

  return jsonb_build_object(
    'face_total', coalesce(v_face, 0),
    'fees_total', coalesce(v_fees, 0),
    'effective_rate_pct', v_rate,
    'book_days_to_pay', v_book_days,
    'days_of_float_gained', v_days_gained,
    'annualized_cost_pct', case when v_days_gained > 0
      then round(v_rate / v_days_gained * 365, 1) end,
    'months', coalesce((select jsonb_agg(jsonb_build_object(
        'month', x.mo, 'invoices', x.n, 'face', x.face, 'fees', x.fees,
        'rate_pct', round(x.fees / nullif(x.face, 0) * 100, 2)) order by x.mo)
      from (select to_char(date_trunc('month', i.invoice_date), 'YYYY-MM') mo,
                   count(*) n, round(sum(i.total), 2) face,
                   round(sum(i.factoring_fee), 2) fees
              from invoices i
             where i.factored_at is not null and coalesce(i.factoring_fee, 0) > 0 and i.total > 0
             group by 1) x), '[]'::jsonb),
    'as_of', now());
end;
$function$;

-- fleet_ops_extras: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.fleet_ops_extras(p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  win_days numeric := greatest(extract(epoch from (p_end - p_start)) / 86400.0, 1);
  weeks numeric := greatest(win_days / 7.0, 0.1);
  loads_n int; total_mi numeric; empty_mi numeric; drivers_n int;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select count(*), coalesce(sum(miles),0) + coalesce(sum(empty_miles),0),
         coalesce(sum(empty_miles),0), count(distinct driver_id) filter (where driver_id is not null)
    into loads_n, total_mi, empty_mi, drivers_n
    from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;

  return jsonb_build_object(
    'deadhead_miles_per_dispatch', case when loads_n > 0 then round(empty_mi / loads_n, 0) end,
    'miles_per_driver_per_week',   case when drivers_n > 0 then round(total_mi / drivers_n / weeks, 0) end,
    'loads_per_day',               round(loads_n / win_days, 1),
    'miles_per_day',               round(total_mi / win_days, 0),
    'working_drivers',             drivers_n);
end;
$function$;

-- fuel_efficiency_by_truck: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.fuel_efficiency_by_truck(p_days integer DEFAULT 45)
 RETURNS TABLE(truck_id bigint, unit_number text, loaded_miles numeric, deadhead_miles numeric, total_miles numeric, gallons numeric, implied_mpg numeric, expected_gallons numeric, gallon_variance_pct numeric, diesel_spend numeric, nonfuel_spend numeric, nondiesel_gallons numeric, eld_miles numeric, miles_basis text, gallons_untracked numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  return query
  with mi as (
    select l.truck_id as tid,
           sum(coalesce(l.miles,0))       as loaded,
           sum(coalesce(l.empty_miles,0)) as deadhead
      from public.loads l
     where l.status in ('completed','billed')
       and l.delivery_time > now() - make_interval(days => p_days)
       and l.truck_id is not null
     group by l.truck_id
  ), em as (
    select e.truck_id as tid, sum(e.miles) as mi
      from public.eld_daily_miles e
     where e.day > current_date - p_days and e.truck_id is not null
     group by e.truck_id
  ), basis as (
    select t.id as bid, t.unit_number as unit,
           coalesce(mi.loaded,0) as loaded, coalesce(mi.deadhead,0) as deadhead,
           coalesce(em.mi,0) as eld_mi,
           case when coalesce(em.mi,0) > 0 then em.mi
                else coalesce(mi.loaded,0)+coalesce(mi.deadhead,0) end as tot,
           case when coalesce(em.mi,0) > 0 then 'eld' else 'booked' end as mb
      from public.trucks t
      left join mi on mi.tid = t.id
      left join em on em.tid = t.id
     where t.status <> 'retired'
  ), fu as (
    select b.bid as tid,
           coalesce(sum(f.gallons) filter (where coalesce(f.gallons,0)>0
             and (b.mb = 'booked' or exists (
               select 1 from public.eld_daily_miles e
                where e.truck_id = b.bid and e.day = f.transaction_time::date))),0) as gal,
           coalesce(sum(f.gallons) filter (where coalesce(f.gallons,0)>0
             and b.mb = 'eld' and not exists (
               select 1 from public.eld_daily_miles e
                where e.truck_id = b.bid and e.day = f.transaction_time::date)),0) as gal_untracked,
           coalesce(sum(f.amount)  filter (where coalesce(f.gallons,0)>0),0) as diesel_spend,
           coalesce(sum(f.amount)  filter (where coalesce(f.gallons,0)=0 and f.amount>0),0) as nonfuel,
           coalesce(sum(f.gallons) filter (where lower(coalesce(f.fuel_type,'')) ~ '(unleaded|ethanol|gasoline|premium|regular|e85|midgrade)'),0) as nondiesel_gal
      from basis b
      join public.fuel_transactions f
        on f.truck_id = b.bid
       and f.transaction_time > now() - make_interval(days => p_days)
     group by b.bid
  )
  select b.bid, b.unit,
         b.loaded, b.deadhead, b.tot,
         coalesce(fu.gal,0),
         case when coalesce(fu.gal,0) > 0 and b.tot > 0 then round(b.tot/fu.gal, 2) end,
         round(b.tot/6.5),
         case when b.tot > 0
              then round((coalesce(fu.gal,0)/nullif(b.tot/6.5,0)-1)*100) end,
         coalesce(fu.diesel_spend,0), coalesce(fu.nonfuel,0), coalesce(fu.nondiesel_gal,0),
         round(b.eld_mi), b.mb, coalesce(fu.gal_untracked,0)
    from basis b
    left join fu on fu.tid = b.bid
   order by 9 desc nulls last;
end;
$function$;

-- insight_detail: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.insight_detail(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ins       public.trux_insights;
  prefix    text;
  subject   text;
  why       text;
  records   jsonb := '[]'::jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;

  select * into ins from public.trux_insights where id = p_id;
  if not found then raise exception 'Insight not found'; end if;
  prefix := split_part(ins.dedup_key, ':', 1);

  -- ---- why Forest flagged it (the rule, in plain English) ----
  why := case prefix
    when 'fuel_product'  then 'A diesel truck physically cannot burn gasoline or ethanol (E85). Buying it on this truck''s fuel card means the fuel is going into another vehicle, a can, or being resold — classic card misuse. Every non-diesel fill on this card in the last 30 days is listed below.'
    when 'fuel_cash'     then 'A fuel card is for fuel. Charges with 0 gallons are cash advances or fees — a common leakage/theft vector. Forest flags a truck whose non-fuel charges top $500 in 30 days (critical over $2,000, or when they exceed the truck''s actual diesel spend). Each such charge is listed below.'
    when 'fuel_overflow' then 'This single transaction is larger than any one truck''s tanks can hold (>200 gal), so part of the fuel went into a second tank or a different vehicle.'
    when 'fuel_recon'    then 'Forest compared gallons purchased against the miles this truck actually drove — dispatch (loaded) PLUS deadhead (empty) — at ~6.5 MPG over 45 days. It bought materially more fuel than those miles justify, so the excess may be diverted. Deadhead is included so a truck that runs empty a lot is not flagged unfairly.'
    when 'factor_reserve_stuck' then 'This invoice was sold to the factor over 45 days ago and the reserve portion still hasn''t been released. Brokers usually pay the factor within that window, so the remainder is likely YOUR money sitting at the factor — ask them for a settlement status on this invoice.'
    when 'honeypot' then 'These decoy records exist for exactly one reason: to catch intruders. Nothing in Truxon — no page, no job, no report, not even Forest — ever reads this table, so ANY access means someone is exploring the database who should not be. The rows below show exactly who, from where, and when. If this was not you or an authorized security test, rotate the affected keys immediately.'
    when 'unprofitable_truck' then 'This truck''s fuel cost exceeded the revenue it earned this week.'
    when 'toll_violation'     then 'This toll posted as a VIOLATION (a missed or unpaid toll), which is billed at a penalty rate above the normal toll — an avoidable cost.'
    when 'detention'          then 'ELD dwell time shows this truck sat past the free time at a stop, so the broker owes detention — bill it before the 14-day window closes.'
    else coalesce(ins.detail, 'Forest surfaced this from the scheduled scan.')
  end;

  -- ---- evidence records, per finding type ----
  if prefix in ('fuel_product','fuel_cash','fuel_recon','unprofitable_truck') then
    select 'Truck '||coalesce(t.unit_number,'?') into subject from public.trucks t where t.id = ins.entity_id;
    select coalesce(jsonb_agg(r order by (r->>'when') desc), '[]'::jsonb) into records
    from (
      select jsonb_build_object(
        'when',     to_char(f.transaction_time, 'YYYY-MM-DD HH24:MI'),
        'driver',   coalesce(nullif(f.driver_name,''), (select d.full_name from public.drivers d where d.id = f.driver_id), '—'),
        'card',     case when coalesce(f.card_last_four,'') <> '' then '…'||f.card_last_four else '—' end,
        'merchant', coalesce(nullif(f.merchant,''), '—'),
        'location', coalesce(nullif(f.merchant_city,''),'?')||coalesce(', '||nullif(f.merchant_state,''),''),
        'product',  coalesce(nullif(f.fuel_type,''), '—'),
        'gallons',  coalesce(f.gallons, 0),
        'amount',   coalesce(f.amount, 0)
      ) as r
      from public.fuel_transactions f
      where f.truck_id = ins.entity_id
        and f.transaction_time > now() - interval '45 days'
        and (prefix <> 'fuel_product' or lower(coalesce(f.fuel_type,'')) ~ '(unleaded|ethanol|gasoline|premium|regular|e85|midgrade)')
        and (prefix <> 'fuel_cash'    or (coalesce(f.gallons,0) = 0 and f.amount > 0))
    ) x;

  elsif prefix = 'fuel_overflow' then
    select 'Truck '||coalesce(t.unit_number,'?') into subject from public.trucks t where t.id = ins.entity_id;
    select jsonb_build_array(jsonb_build_object(
      'when',     to_char(f.transaction_time,'YYYY-MM-DD HH24:MI'),
      'driver',   coalesce(nullif(f.driver_name,''),'—'),
      'card',     case when coalesce(f.card_last_four,'')<>'' then '…'||f.card_last_four else '—' end,
      'merchant', coalesce(nullif(f.merchant,''),'—'),
      'location', coalesce(nullif(f.merchant_city,''),'?')||coalesce(', '||nullif(f.merchant_state,''),''),
      'product',  coalesce(nullif(f.fuel_type,''),'—'),
      'gallons',  coalesce(f.gallons,0), 'amount', coalesce(f.amount,0)))
    into records
    from public.fuel_transactions f where f.id = nullif(split_part(ins.dedup_key,':',2),'')::bigint;

  elsif prefix = 'toll_violation' then
    select jsonb_build_array(jsonb_build_object(
      'when',     to_char(coalesce(tt.post_date_time, tt.exit_date_time),'YYYY-MM-DD HH24:MI'),
      'unit',     coalesce(nullif(tt.vehicle_number,''),'—'),
      'plate',    coalesce(nullif(tt.plate_number,''),'—'),
      'agency',   coalesce(nullif(tt.toll_agency_name,''),'—')||coalesce(' ('||nullif(tt.toll_agency_state,'')||')',''),
      'plaza',    coalesce(nullif(tt.exit_plaza_name,''), nullif(tt.entry_plaza_name,''), '—'),
      'charge',   coalesce(tt.toll_charge,0)))
    into records
    from public.toll_transactions tt where tt.id = nullif(split_part(ins.dedup_key,':',2),'')::bigint;
    select 'Toll' into subject;

  elsif ins.entity_type = 'customer' then
    select company_name into subject from public.customers where id = ins.entity_id;
    select coalesce(jsonb_agg(r order by (r->>'issued')), '[]'::jsonb) into records from (
      select jsonb_build_object(
        'invoice', i.invoice_number,
        'issued',  to_char(i.created_at,'YYYY-MM-DD'),
        'amount',  coalesce(i.total, 0),
        'status',  i.status,
        'paid',    coalesce(to_char(i.paid_at,'YYYY-MM-DD'),'unpaid')
      ) as r
      from public.invoices i
      where i.customer_id = ins.entity_id and coalesce(i.paid_at, null) is null
      order by i.created_at limit 50
    ) x;

  elsif ins.entity_type = 'load' then
    select jsonb_build_array(jsonb_build_object(
      'load',      l.load_number, 'status', l.status,
      'lane',      coalesce(l.pickup_state,'?')||' -> '||coalesce(l.delivery_state,'?'),
      'delivery',  to_char(l.delivery_time,'YYYY-MM-DD HH24:MI'),
      'rate',      coalesce(l.rate,0),
      'driver',    (select d.full_name from public.drivers d where d.id = l.driver_id),
      'truck',     (select t.unit_number from public.trucks t where t.id = l.truck_id)))
    into records
    from public.loads l where l.id = ins.entity_id;
    select 'Load '||coalesce((select load_number from public.loads where id = ins.entity_id),'?') into subject;

  elsif ins.entity_type = 'driver' then
    select d.full_name into subject from public.drivers d where d.id = ins.entity_id;
    select jsonb_build_array(jsonb_build_object(
      'driver', d.full_name, 'status', d.status,
      'license', coalesce(nullif(d.license_number,''),'—'),
      'license_expires', coalesce(to_char(d.license_expiration,'YYYY-MM-DD'),'—'),
      'phone', coalesce(nullif(d.phone,''),'—')))
    into records from public.drivers d where d.id = ins.entity_id;

  elsif prefix = 'honeypot' then
    subject := 'Decoy "' || split_part(ins.dedup_key, ':', 2) || '"';
    select coalesce(jsonb_agg(r order by (r->>'when') desc), '[]'::jsonb) into records
    from (
      select jsonb_build_object(
        'when',     to_char(h.hit_at, 'YYYY-MM-DD HH24:MI:SS'),
        'who',      coalesce(h.jwt_claims->>'email', h.jwt_claims->>'sub', '—'),
        'api_role', coalesce(h.jwt_claims->>'role', '(direct DB: ' || coalesce(h.db_role,'?') || ')'),
        'ip',       coalesce(h.headers->>'x-real-ip', h.headers->>'cf-connecting-ip', h.headers->>'x-forwarded-for', '—'),
        'client',   left(coalesce(h.headers->>'user-agent', '—'), 60)
      ) as r
      from app_private.honeypot_hits h
      where h.object = split_part(ins.dedup_key, ':', 2)
        and h.hit_at::date = split_part(ins.dedup_key, ':', 3)::date
      limit 100
    ) x;

  elsif ins.entity_type = 'truck' then
    select 'Truck '||coalesce(unit_number,'?') into subject from public.trucks where id = ins.entity_id;
    select jsonb_build_array(jsonb_build_object(
      'unit', t.unit_number, 'status', t.status,
      'plate', coalesce(nullif(t.plate_number,''),'—'),
      'plate_expires', coalesce(to_char(t.plate_expiry,'YYYY-MM-DD'),'—')))
    into records from public.trucks t where t.id = ins.entity_id;
  end if;

  return jsonb_build_object(
    'id', ins.id, 'title', ins.title, 'detail', ins.detail,
    'severity', ins.severity, 'category', ins.category,
    'first_seen', ins.first_seen, 'last_seen', ins.last_seen,
    'subject', coalesce(subject, ins.entity_type),
    'why', why,
    'records', records
  );
end;
$function$;

-- load_route: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.load_route(p_load_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_truck bigint;
  v_from timestamptz;
  v_to timestamptz;
  n bigint;
  step int;
  out jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;

  select l.truck_id,
         coalesce(l.pickup_time, (select min(s.stop_time) from load_stops s where s.load_id = l.id)) - interval '2 hours',
         least(coalesce(l.delivery_time, now()) + interval '4 hours', now())
    into v_truck, v_from, v_to
    from loads l where l.id = p_load_id;
  if v_truck is null or v_from is null then
    return jsonb_build_object('points', '[]'::jsonb, 'reason', 'no truck or window');
  end if;

  select count(*) into n from eld_location_history h
   where h.truck_id = v_truck and h.ts between v_from and v_to;
  if n = 0 then
    return jsonb_build_object('points', '[]'::jsonb, 'reason', 'no breadcrumbs in window');
  end if;
  step := greatest(1, (n / 500)::int);

  select jsonb_build_object(
    'points', coalesce(jsonb_agg(jsonb_build_array(round(q.lat, 5), round(q.lng, 5)) order by q.ts), '[]'::jsonb),
    'from', min(q.ts), 'to', max(q.ts), 'total_pings', n, 'sampled_every', step)
    into out
  from (
    select h.lat, h.lng, h.ts,
           row_number() over (order by h.ts) as rn
      from eld_location_history h
     where h.truck_id = v_truck and h.ts between v_from and v_to
       and h.lat is not null and h.lng is not null
  ) q
  where q.rn % step = 0;
  return out;
end;
$function$;

-- per_truck_pnl: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.per_truck_pnl(p_months integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_start timestamptz := date_trunc('month', now()) - make_interval(months => greatest(p_months, 1) - 1);
  v_rows jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;

  select jsonb_agg(t order by t.net desc nulls last) into v_rows from (
    select tk.unit_number as unit,
           tk.ownership,
           coalesce(r.revenue, 0) as revenue,
           coalesce(r.loads, 0) as loads,
           coalesce(f.fuel, 0) as fuel,
           coalesce(tl.tolls, 0) as tolls,
           coalesce(mx.maint, 0) as maintenance,
           coalesce(r.driver_pay, 0) as driver_pay,
           round(coalesce(tk.monthly_payment, 0) * p_months, 2) as payment,
           round(coalesce(r.revenue, 0) - coalesce(f.fuel, 0) - coalesce(tl.tolls, 0)
                 - coalesce(mx.maint, 0) - coalesce(r.driver_pay, 0)
                 - coalesce(tk.monthly_payment, 0) * p_months, 2) as net,
           case when coalesce(tk.monthly_payment, 0) > 0
             then round((coalesce(r.revenue, 0) - coalesce(f.fuel, 0) - coalesce(tl.tolls, 0)
                         - coalesce(mx.maint, 0) - coalesce(r.driver_pay, 0))
                        / (tk.monthly_payment * p_months), 2) end as roi_x
      from trucks tk
      left join lateral (
        select round(sum(l.rate), 2) revenue, count(*) loads,
               round(sum(l.miles * coalesce(d.pay_per_mile, 0)
                 + case when d.empty_miles_paid then coalesce(l.empty_miles, 0) * d.pay_per_empty_mile else 0 end), 2) driver_pay
          from loads l left join drivers d on d.id = l.driver_id
         where l.truck_id = tk.id and l.status in ('completed','billed')
           and l.delivery_time >= v_start) r on true
      left join lateral (
        select round(sum(coalesce(ft.net_of_discount, ft.amount)), 2) fuel
          from fuel_transactions ft
         where ft.truck_id = tk.id and ft.transaction_time >= v_start) f on true
      left join lateral (
        select round(sum(tt.toll_charge), 2) tolls
          from toll_transactions tt
         where tt.truck_id = tk.id and tt.exit_date_time >= v_start) tl on true
      left join lateral (
        select round(sum(m.cost), 2) maint
          from maintenance_records m
         where m.truck_id = tk.id and m.status = 'completed' and m.date_completed >= v_start::date) mx on true
     where tk.status <> 'retired') t;

  return jsonb_build_object(
    'months', p_months,
    'payments_entered', (select count(*) from trucks where status <> 'retired' and coalesce(monthly_payment, 0) > 0),
    'trucks_total', (select count(*) from trucks where status <> 'retired'),
    'trucks', coalesce(v_rows, '[]'::jsonb),
    'as_of', now());
end;
$function$;

-- pod_capture_rate: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.pod_capture_rate(p_start timestamp with time zone, p_end timestamp with time zone, p_hours integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare delivered int; captured int; have_pod int; avg_hrs numeric;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with dl as (
    select l.id, l.delivery_time,
           (select min(d.uploaded_at) from public.documents d
             where d.entity_type='load' and d.entity_id=l.id
               and lower(d.doc_type) in ('pod','bol','receipt','scale')) as pod_at
      from public.loads l
     where l.status in ('delivered','completed','billed')
       and l.delivery_time >= p_start and l.delivery_time < p_end
  )
  select count(*),
         count(*) filter (where pod_at is not null and pod_at <= delivery_time + make_interval(hours => p_hours)),
         count(*) filter (where pod_at is not null),
         round(avg(extract(epoch from (pod_at - delivery_time)) / 3600.0)
                 filter (where pod_at is not null)::numeric, 1)
    into delivered, captured, have_pod, avg_hrs
    from dl;

  return jsonb_build_object(
    'window_hours', p_hours,
    'delivered_loads', delivered,
    'pod_on_file', have_pod,
    'captured_within', captured,
    'capture_rate_pct', case when delivered > 0 then round(captured::numeric / delivered * 100, 1) end,
    'pod_on_file_pct', case when delivered > 0 then round(have_pod::numeric / delivered * 100, 1) end,
    'avg_hours_to_pod', avg_hrs);
end;
$function$;

-- qbo_writeoff_seed: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.qbo_writeoff_seed()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  insert into qbo_writeoff_proposals (invoice_id, amount)
  select i.id, i.qbo_balance
    from invoices i
   where i.factored_at is not null
     and i.status = 'sent'
     and i.source = 'qbo'
     and i.qbo_balance > 0
     and i.qbo_balance <= least(0.15 * i.total, 500)
     and not exists (select 1 from qbo_writeoff_proposals p where p.invoice_id = i.id)
  on conflict (invoice_id) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$function$;

-- sales_pipeline: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.sales_pipeline(p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  received int; won int; lost int; quoted_open int; new_open int; decided int;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;

  -- volume received in the window (excludes spam)
  select count(*) into received from public.quote_requests
   where status <> 'spam' and created_at >= p_start and created_at < p_end;

  -- outcomes on requests received in the window
  select count(*) filter (where status='won'),
         count(*) filter (where status='lost'),
         count(*) filter (where status='quoted'),
         count(*) filter (where status='new')
    into won, lost, quoted_open, new_open
    from public.quote_requests
   where status <> 'spam' and created_at >= p_start and created_at < p_end;
  decided := won + lost;

  return jsonb_build_object(
    'quotes_received', received,
    'won', won, 'lost', lost,
    'open_new', new_open, 'open_quoted', quoted_open,
    'open_pipeline', new_open + quoted_open,
    'win_rate_pct', case when decided > 0 then round(won::numeric / decided * 100, 1) end,
    'quoted_rate_pct', case when received > 0 then round((won + lost + quoted_open)::numeric / received * 100, 1) end);
end;
$function$;

-- security_audit_recent: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.security_audit_recent(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  return coalesce((select jsonb_agg(r order by r.id desc) from (
    select id, at, event_type, severity, actor_email, actor_role, session_role, ip, detail
    from app_private.security_audit order by id desc limit greatest(1, least(p_limit, 500))
  ) r), '[]'::jsonb);
end;
$function$;

-- security_audit_verify: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.security_audit_verify()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare
  r record; v_prev text := 'GENESIS'; v_calc text; v_checked int := 0;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') = 'admin') then
    raise exception 'Not enough permissions';
  end if;
  for r in select * from app_private.security_audit order by id loop
    v_calc := encode(extensions.digest(
      v_prev || '|' || r.at::text || '|' || r.event_type || '|' || coalesce(r.severity,'') || '|'
        || coalesce(r.actor_uid::text,'') || '|' || coalesce(r.detail::text,'{}'), 'sha256'), 'hex');
    if v_calc <> r.row_hash or r.prev_hash <> v_prev then
      return jsonb_build_object('intact', false, 'broken_at_id', r.id, 'checked', v_checked);
    end if;
    v_prev := r.row_hash; v_checked := v_checked + 1;
  end loop;
  return jsonb_build_object('intact', true, 'checked', v_checked);
end;
$function$;

-- security_console: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.security_console()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;

  select jsonb_build_object(
    'lockdown', coalesce((select value = 'on' from app_private.system_flags where key='lockdown'), false),
    'audit_chain', public.security_audit_verify(),
    'guard_armed', exists(select 1 from pg_event_trigger where evtname = 'guard_destructive_ddl_trg'),
    'honeytokens', (select count(*) from app_private.honeytokens),
    'canary_present', exists(select 1 from public.profiles where id = '00000000-0000-4000-8000-00000000ca11' and not is_active),
    'baseline_items', (select count(*) from app_private.security_baseline),
    'audit_events_total', (select count(*) from app_private.security_audit),
    'open_findings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', id, 'severity', severity, 'title', title, 'last_seen', last_seen)
             order by (severity='critical') desc, last_seen desc)
      from public.trux_insights
      where status <> 'resolved'
        and split_part(dedup_key,':',1) in
            ('honeypot','honeytoken','admin_granted','posture_drift','canary_user','ransom_ddl')
    ), '[]'::jsonb),
    'critical_open', (select count(*) from public.trux_insights
                       where status <> 'resolved' and severity = 'critical'
                         and split_part(dedup_key,':',1) in
                             ('honeypot','honeytoken','admin_granted','posture_drift','canary_user','ransom_ddl')),
    'recent_audit', public.security_audit_recent(30)
  ) into v;
  return v;
end;
$function$;

-- sentinel_open_summary: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.sentinel_open_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare open_n int; crit_n int; warn_n int; snoozed_n int; by_cat jsonb; top jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  select count(*), count(*) filter (where severity='critical'), count(*) filter (where severity='warn')
    into open_n, crit_n, warn_n from public.trux_insights
   where status <> 'resolved' and (snoozed_until is null or snoozed_until < now());
  select count(*) into snoozed_n from public.trux_insights
   where status <> 'resolved' and snoozed_until >= now();
  select coalesce(jsonb_object_agg(category, c), '{}'::jsonb) into by_cat
    from (select category, count(*) c from public.trux_insights
           where status <> 'resolved' and (snoozed_until is null or snoozed_until < now())
           group by category) x;
  select coalesce(jsonb_agg(jsonb_build_object('severity', severity, 'title', title, 'detail', detail)), '[]'::jsonb) into top
    from (select severity, title, detail from public.trux_insights
           where status <> 'resolved' and (snoozed_until is null or snoozed_until < now())
           order by case severity when 'critical' then 0 when 'warn' then 1 else 2 end, last_seen desc limit 8) t;
  return jsonb_build_object('open', open_n, 'critical', crit_n, 'warn', warn_n,
    'snoozed', snoozed_n, 'by_category', by_cat, 'top', top);
end; $function$;

-- sentinel_scan: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.sentinel_scan()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '120s'
AS $function$
declare
  fired int;
  resolved int;
  v_dso numeric;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() = 'admin') then
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
  -- (R8 Block 35) miles basis upgraded to ELD ACTUAL GPS miles when the ELD
  -- covered the truck in the window - includes out-of-route driving, so honest
  -- burns stop false-flagging and parked-idle diversion flags harder. Booked
  -- dispatch+deadhead miles remain the fallback for ELD-dark trucks.
  insert into _findings
  select 'fuel_recon:'||fe.truck_id, 'money', 'warn',
         'Truck '||coalesce(fe.unit_number,'?')||' bought more fuel than its miles justify',
         'Drove '||round(fe.total_miles)::text||' mi ('
           ||case when fe.miles_basis = 'eld' then 'ELD GPS actual' else 'booked, ELD dark' end
           ||') in 45d -> ~'||fe.expected_gallons::text||' gal expected at 6.5 MPG, but purchased '
           ||round(fe.gallons)::text||' gal ('||fe.gallon_variance_pct::text||'% over). Possible diversion.',
         'truck', fe.truck_id
    from public.fuel_efficiency_by_truck(45) fe
   where fe.total_miles >= 2000 and fe.gallons >= 100
     and fe.gallons >= (fe.total_miles/6.5) * 1.25;


  -- ===== FACTORING (added 2026-07-21) =====
  -- Reserve stuck: an invoice was factored 45+ days ago and the factor still
  -- hasn't released the reserve. The broker may well have paid the factor by
  -- now — that remainder is OUR money sitting at Denim. Chase the factor.
  insert into _findings
  select 'factor_reserve_stuck:'||i.id, 'cash',
         case when i.factored_at < now() - interval '75 days' then 'critical' else 'warn' end,
         'Factoring reserve stuck '||(now()::date - i.factored_at::date)||'d — '||i.invoice_number,
         '$'||round(public.invoice_balance(i))||' reserve on '||coalesce(c.company_name,'?')
           ||' unreleased since '||to_char(i.factored_at,'Mon DD')
           ||' ('||coalesce(i.factor_name,'factor')||'). Ask the factor for a settlement status.',
         'customer', i.customer_id
    from public.invoices i
    left join public.customers c on c.id = i.customer_id
   where i.factored_at is not null
     and i.status = 'sent'
     and public.invoice_balance(i) > 0
     and i.factored_at < now() - interval '45 days';


  -- Stranded accessorial (review H-1 net): an APPROVED accessorial whose load
  -- is already invoiced can never be picked up by create_invoice — the money
  -- is approved but uncollectable until someone voids & re-bills or issues a
  -- supplemental invoice. The propose-side filter prevents most of these; this
  -- catches the race (billed between propose and approve).
  insert into _findings
  select 'stranded_accessorial:'||a.id, 'money', 'critical',
         'Approved $'||round(a.amount)||' '||a.atype||' is stranded — load '||l.load_number||' already invoiced',
         initcap(a.atype)||' approved '||to_char(a.decided_at,'Mon DD')||' but the load was invoiced first. '
           ||'Void & re-bill the invoice (voiding reopens the accessorial) or issue a supplemental invoice.',
         'load', l.id
    from public.load_accessorials a
    join public.loads l on l.id = a.load_id
   where a.status = 'approved'
     and l.invoice_id is not null;

  -- ===== SECURITY: honeypot canaries =====
  -- Decoy objects (api_keys, bank_accounts) that nothing legitimate touches.
  -- Hits are recorded by app_private.honeypot_trip; one finding per object/day,
  -- kept alive 30 days so the team can't miss it.
  insert into _findings
  select 'honeypot:' || h.object || ':' || to_char(h.day, 'YYYY-MM-DD'),
         'compliance',
         case when h.worst >= 2 then 'critical' else 'warn' end,
         '🍯 Honeypot "' || h.object || '" accessed ' || h.hits || 'x on '
           || to_char(h.day, 'YYYY-MM-DD') || ' — possible compromise',
         'Decoy table read by: ' || h.whos || '. No legitimate Truxon code or user reads this object. '
           || case when h.worst >= 2
              then 'A NAMED account or database credential did this — treat those credentials as compromised: rotate keys and review the account''s activity.'
              else 'Only the public anon key was used (most likely an outside scanner probing the API). No real data was exposed — the decoy serves fakes — but watch for follow-up findings.' end,
         'security', null
  from (
    select hh.object, hh.hit_at::date as day, count(*) as hits,
           max(case when coalesce(hh.jwt_claims->>'role','') in ('authenticated','service_role')
                      or (hh.jwt_claims is null and coalesce(hh.db_role,'') not in ('authenticator','anon',''))
                    then 2 else 1 end) as worst,
           string_agg(distinct coalesce(hh.jwt_claims->>'email', hh.jwt_claims->>'role', hh.db_role, '?'), ', ') as whos
    from app_private.honeypot_hits hh
    where hh.hit_at > now() - interval '30 days'
    group by hh.object, hh.hit_at::date
  ) h;

  -- ===== SECURITY: permission-posture drift =====
  -- Anything the live posture has that the blessed baseline didn't: a new grant
  -- to anon/authenticated, a newly anon-callable function, or a table that lost
  -- RLS. anon exposure = critical; authenticated / RLS-off = warn.
  insert into _findings
  select 'posture_drift:' || d.kind || ':' || left(regexp_replace(d.item,'[^a-zA-Z0-9_ .]','','g'), 80),
         'compliance',
         case when d.item like 'anon %' or d.kind = 'routine' then 'critical' else 'warn' end,
         case d.kind
           when 'grant'   then '🔓 New table permission: ' || d.item
           when 'routine' then '🔓 Function now callable by anon: ' || d.item
           when 'rls_off' then '🔓 Row-level security is OFF on ' || d.item
         end,
         'The database''s access posture changed from the blessed baseline. '
           || case d.kind
                when 'grant'   then 'A role gained a table privilege it did not have before (' || d.item || '). '
                when 'routine' then 'The public anon key can now execute this function (' || d.item || '). '
                when 'rls_off' then 'This table''s row-level security is disabled, so its policies are not enforced. '
              end
           || 'If you made this change on purpose, re-bless the baseline (Admin → security). If not, an unauthorized grant may have been added — review it and the security audit log immediately.',
         'security', null
  from (
    select kind, item from app_private.security_posture()
    except
    select kind, item from app_private.security_baseline
  ) d;

  -- ===== SECURITY: admin grants =====
  -- Every elevation to admin (from the audit log the profiles tripwire writes)
  -- surfaces as a critical finding until acknowledged. Legit changes you ack;
  -- an unexpected one is an account takeover in progress.
  insert into _findings
  select 'admin_granted:' || a.id::text, 'compliance', 'critical',
         '🛡️ Admin access granted' || coalesce(' to ' || (a.detail->>'username'), ''),
         'An account was made an administrator on ' || to_char(a.at,'Mon DD HH24:MI')
           || coalesce(' by ' || a.actor_email, ' (no signed-in user — a direct database change)')
           || ' (was: ' || coalesce(a.detail->>'from','?') || '). If this was you or an authorized change, '
           || 'acknowledge it. If not, an intruder''s first move is to grant themselves admin — revoke it and '
           || 'rotate credentials now. Full record in the security audit log.',
         'profile', null
  from app_private.security_audit a
  where a.event_type = 'admin_granted' and a.at > now() - interval '30 days';

  -- ===== SECURITY: canary account =====
  -- Any auth activity against the permanently-inactive canary login means
  -- someone is enumerating/spraying your user list. Scans the GoTrue audit log.
  insert into _findings
  select 'canary_user:' || to_char(max(a.created_at), 'YYYYMMDDHH24'),
         'compliance', 'critical',
         '🕵️ Canary login touched — user-list enumeration',
         'The dormant canary account (ap-archive@aidalogistics.com) saw ' || count(*)
           || ' authentication event(s) since ' || to_char(min(a.created_at),'Mon DD HH24:MI')
           || '. Nobody knows its password and it can never log in, so this is someone working through your '
           || 'user list — likely credential spraying. Consider forcing a password reset on all office accounts '
           || 'and check the security audit log for successful logins elsewhere.',
         'security', null
  from auth.audit_log_entries a
  where a.created_at > now() - interval '24 hours'
    and a.payload::text ilike '%ap-archive@aidalogistics.com%'
  having count(*) > 0;

  -- ===== CASH: detention review queue aging =====
  -- The daily cron PROPOSES detention accessorials; only an office click turns
  -- them into invoice money. If proposals sit undecided >48h they quietly age
  -- past billing windows — one standing nudge until the queue is cleared.
  insert into _findings
  select 'accessorial_review_queue', 'cash', 'warn',
         '⏱️ ' || count(*) || ' proposed detention charge' || case when count(*) = 1 then '' else 's' end
           || ' (~$' || round(sum(a.amount)) || ') await' || case when count(*) = 1 then 's' else '' end || ' review',
         count(*) || ' detention accessorial' || case when count(*) = 1 then ' has' else 's have' end
           || ' been sitting in "proposed" for over 48 hours (~$' || round(sum(a.amount))
           || ' total, oldest from ' || to_char(min(a.created_at), 'Mon DD') || '). Approve or reject them on '
           || 'Accounting → Detention ("Bill it") — approved charges ride the next invoice automatically, but '
           || 'nothing bills while they wait, and brokers get less cooperative as the delivery ages.',
         'invoice', null
    from public.load_accessorials a
   where a.status = 'proposed' and a.created_at < now() - interval '48 hours'
  having count(*) > 0;

  -- ===== OPS: off-site db-backup freshness =====
  -- The nightly db-backup edge fn dumps to the private db-backups bucket; the
  -- watchdog only watches the NAS heartbeat, so a silently-broken bucket cron
  -- would go unnoticed until a restore is needed. Quiet where the bucket does
  -- not exist (local/dev).
  insert into _findings
  select 'backup_bucket_stale', 'compliance', 'critical',
         '💾 Off-site database backup is stale',
         'The db-backups bucket''s newest object is from '
           || coalesce(to_char((select max(o.created_at) from storage.objects o where o.bucket_id = 'db-backups'), 'Mon DD HH24:MI'), 'NEVER')
           || ' — more than 36h ago. The nightly dump (03:37 UTC) is not landing. Check the db-backup '
           || 'edge function logs and the pg_cron schedule; a business without a fresh backup is one '
           || 'ransomware event away from losing books.',
         'security', null
   where exists (select 1 from storage.buckets b where b.id = 'db-backups')
     and coalesce((select max(o.created_at) from storage.objects o where o.bucket_id = 'db-backups'),
                  'epoch'::timestamptz) < now() - interval '36 hours';

  -- ===== SECURITY: nobody has MFA yet =====
  -- Standing nudge while ZERO office users have a verified second factor;
  -- resolves itself the moment the first one enrolls.
  insert into _findings
  select 'mfa_coverage_zero', 'compliance', 'warn',
         '🔐 No office account has two-factor auth yet',
         'MFA is live (My Account → Two-factor authentication) but no admin, dispatcher, accountant or '
           || 'maintenance account has enrolled an authenticator app. A single phished password is currently '
           || 'enough to reach the books. Enrolling takes about a minute.',
         'security', null
   where not exists (
     select 1 from auth.mfa_factors f
       join public.profiles p on p.id = f.user_id and p.is_active
         and p.role in ('admin','dispatcher','accountant','maintenance')
      where f.status = 'verified')
     and exists (select 1 from public.profiles where is_active
                   and role in ('admin','dispatcher','accountant','maintenance'));

  -- ===== CASH: broken promise-to-pay =====
  -- A broker's most-recent promised pay date on an invoice has passed and the
  -- invoice is still unpaid. Each is a warm collections lead the office already
  -- worked once — chase it before it goes cold. One finding per invoice; clears
  -- when it's paid or a new promise is logged.
  insert into _findings
  select 'broken_promise:' || p.invoice_id,
         'cash', 'warn',
         '🤝 Broken promise-to-pay — ' || coalesce(c.company_name, 'a broker') || ' inv ' || i.invoice_number,
         coalesce(c.company_name, 'A broker') || ' promised to pay invoice ' || i.invoice_number
           || ' (~$' || round(public.invoice_balance(i)) || ') by ' || to_char(p.promised_date, 'Mon DD')
           || ' but it''s still open ' || (current_date - p.promised_date) || ' day(s) later. Call them back — '
           || 'a missed promise is the strongest signal to escalate. See Accounting → Collections.',
         'invoice', p.invoice_id
    from (
      select distinct on (cn.invoice_id) cn.invoice_id, cn.promised_date
        from public.collection_notes cn
       where cn.invoice_id is not null and cn.promised_date is not null
       order by cn.invoice_id, cn.created_at desc, cn.id desc
    ) p
    join public.invoices i on i.id = p.invoice_id
    left join public.customers c on c.id = i.customer_id
   where p.promised_date < current_date
     and i.status = 'sent'
     and public.invoice_balance(i) > 0;

  -- ===== CASH: customer over credit exposure =====
  -- A broker's total float (open AR + unbilled + committed open loads) is past
  -- the pay-history-derived limit — book more and you're financing them. One
  -- finding per customer; clears when they pay down or the limit rises.
  insert into _findings
  select 'over_exposure:' || e.customer_id, 'cash', 'warn',
         '🚦 ' || e.company_name || ' is over its credit exposure limit',
         e.company_name || ' is carrying $' || e.exposure || ' of exposure (open AR + unbilled + committed '
           || 'loads) against a $' || e.credit_limit || ' limit — $' || e.over_by || ' over'
           || coalesce(', and averages ' || round(e.avg_days_to_pay) || ' days to pay', '')
           || '. Get paid down or hold new bookings before you extend more credit. Booking screen shows the same guard.',
         'customer', e.customer_id
    from public.customers_over_exposure() e;

  -- ===== REVENUE: a regular broker has gone quiet (churn risk) =====
  -- A customer who shipped on a steady cadence and has now been silent for well
  -- past that cadence is early churn — cheaper to win back now than to replace.
  -- Resolves the moment they book again.
  insert into _findings
  select 'customer_quiet:' || q.customer_id, 'cash', 'warn',
         '📉 ' || q.company_name || ' has gone quiet',
         q.company_name || ' shipped ' || q.prior_loads || ' load(s) in the prior 180 days (about one every '
           || round(q.cadence_days) || ' days) but nothing in the last ' || q.days_since || ' days. A regular '
           || 'broker going silent is early churn — a call now is cheaper than replacing the revenue. '
           || 'Their full history is on the customer page.',
         'customer', q.customer_id
    from (
      select c.id as customer_id, c.company_name,
             count(l.id) as prior_loads,
             floor(extract(epoch from (now() - max(l.created_at))) / 86400.0)::int as days_since,
             180.0 / nullif(count(l.id), 0) as cadence_days
        from public.customers c
        join public.loads l on l.customer_id = c.id and l.created_at >= now() - interval '180 days'
       group by c.id, c.company_name
    ) q
   where q.prior_loads >= 4
     and q.days_since > greatest(45, (2 * q.cadence_days)::int);

  -- ===== DATA: revenue-integrity gaps on billed/completed loads =====
  -- A completed or billed load with no rate or no miles silently distorts every
  -- $/mile, margin, and break-even number it touches. One rolling finding lists
  -- the offenders (last 120 days) so the office can patch them in a batch.
  insert into _findings
  select 'load_data_gaps', 'data', 'warn',
         '🧮 ' || count(*) || ' billed/completed load(s) missing rate or miles',
         count(*) || ' load(s) delivered in the last 120 days have no rate and/or no miles, so they drag down '
           || 'every revenue-per-mile, margin, and break-even figure they touch. Fix them on the load record: '
           || string_agg(l.load_number || ' (' ||
                case when coalesce(l.rate,0) = 0 and coalesce(l.miles,0) = 0 then 'no rate + miles'
                     when coalesce(l.rate,0) = 0 then 'no rate'
                     else 'no miles' end || ')', ', ' order by l.delivery_time desc),
         'load', null
    from public.loads l
   where l.status in ('completed','billed')
     and l.delivery_time >= now() - interval '120 days'
     and (coalesce(l.rate,0) = 0 or coalesce(l.miles,0) = 0)
  having count(*) > 0;

  -- ===== DATA (customer regulatory-number quality) =====
  -- Structurally-invalid MC/USDOT stored on active customers (USDOT = 5-8 digits,
  -- MC docket = 5-7 digits), or a customer carrying one identifier but not the
  -- other (usually an incomplete/mis-scanned record). Report-only: FMCSA content
  -- verification is enforced at write time (_shared/fmcsa.ts); this catches numbers
  -- that were already stored before that gate existed.
  insert into _findings
  select 'cust_dot_malformed:'||c.id, 'data', 'warn',
         'Customer "'||c.company_name||'" has a malformed USDOT number',
         'Stored USDOT "'||c.usdot_number||'" is not 5-8 digits - likely an OCR or import error',
         'customer', c.id
    from public.customers c
   where coalesce(c.do_not_use,false) = false
     and nullif(btrim(coalesce(c.usdot_number,'')),'') is not null
     and regexp_replace(c.usdot_number,'\D','','g') !~ '^\d{5,8}$';

  insert into _findings
  select 'cust_mc_malformed:'||c.id, 'data', 'warn',
         'Customer "'||c.company_name||'" has a malformed MC number',
         'Stored MC "'||c.mc_number||'" is not 5-7 digits - likely an OCR or import error',
         'customer', c.id
    from public.customers c
   where coalesce(c.do_not_use,false) = false
     and nullif(btrim(coalesce(c.mc_number,'')),'') is not null
     and regexp_replace(c.mc_number,'\D','','g') !~ '^\d{5,7}$';

  -- ===== OPS: chronic idlers (R8 Block 2) =====
  -- Trucks burning >35% of engine-on time stationary over the last 14 days,
  -- with a >=7-idle-hour floor so a truck barely driven can't trip it.
  -- Waste estimate: ~0.8 gal/hr idle burn at the fleet's actual avg $/gal.
  insert into _findings
  select 'idle_chronic:'||(t->>'truck_id'), 'ops', 'warn',
         'Unit '||coalesce(tr.unit_number, '?')||' idles '||(t->>'idle_pct')||'% of engine time',
         'Last 14 days: '||(t->>'idle_hours')||' idle hours (~'
           ||round((t->>'idle_hours')::numeric * 0.8, 0)||' gal, ~$'
           ||round((t->>'idle_hours')::numeric * 0.8 * coalesce((
               select sum(coalesce(net_of_discount, amount)) / nullif(sum(gallons), 0)
                 from public.fuel_transactions
                where status <> 'Declined' and fuel_type = 'Diesel'
                  and transaction_time > now() - interval '30 days'), 3.85), 0)
           ||' burned standing still)',
         'truck', (t->>'truck_id')::bigint
    from jsonb_array_elements(public.idle_summary(14)->'trucks') t
    left join public.trucks tr on tr.id = (t->>'truck_id')::bigint
   where (t->>'idle_pct')::numeric > 35
     and (t->>'idle_hours')::numeric >= 7;

  -- ===== OPS: speeding (R8 Block 7) =====
  -- warn at >=30 min over 75 mph in 14d; critical at >=15 min over 80.
  insert into _findings
  select 'speeding_hot:'||(t->>'truck_id'),
         'ops',
         case when (t->>'min_over_80')::numeric >= 15 then 'critical' else 'warn' end,
         'Unit '||(t->>'unit')||' speeding - '||(t->>'min_over_75')||' min at 75+ mph (14d)',
         'Max '||(t->>'max_speed')||' mph'
           ||coalesce(' near '||nullif(t->>'worst_place',''),'')
           ||coalesce(' at '||to_char((t->>'worst_at')::timestamptz,'Mon DD HH24:MI'),'')
           ||'. '||(t->>'min_over_80')||' min at 80+. CSA Unsafe Driving BASIC + insurance exposure.',
         'truck', (t->>'truck_id')::bigint
    from jsonb_array_elements(public.speeding_summary(14)->'trucks') t
   where (t->>'min_over_75')::numeric >= 30
      or (t->>'min_over_80')::numeric >= 15;

  -- ===== MAINTENANCE: dark ELD units (R8 Block 12b) =====
  -- Active (non-retired) trucks whose ELD hasn't reported in 48h - or that
  -- have no linked ELD at all. Grace: trucks created in the last 7 days.
  insert into _findings
  select 'eld_dark:'||t.id, 'maintenance',
         case when le.last_ts is null or le.last_ts < now() - interval '14 days'
              then 'critical' else 'warn' end,
         -- (R9 #58) escalation ladder: past two weeks the title carries the week
         -- count and BUMPS weekly, so the daily brief re-surfaces it instead of
         -- letting a months-dark unit become wallpaper
         case when le.last_ts is not null and le.last_ts < now() - interval '14 days'
              then 'Unit '||t.unit_number||' ELD STILL dark - week '
                   ||ceil(extract(epoch from now() - le.last_ts) / 604800)::int
              when le.last_ts is null
              then 'Unit '||t.unit_number||' has no ELD linked'
              else 'Unit '||t.unit_number||' ELD is dark' end,
         case when le.last_ts is null
              then 'No ELD is linked to this truck - HOS logs, GPS, odometer, and IFTA miles are all blind. Either install/link an ELD or retire the unit in Truxon so it stops counting against compliance.'
              else 'Last ELD report '||to_char(le.last_ts, 'Mon DD HH24:MI')||' ('
                   ||extract(day from now() - le.last_ts)||' days ago). HOS compliance and all telematics analytics are blind for this unit. If the truck is parked long-term, mark it out of service; if it runs, this is an unplugged/dead ELD - fix it this week.' end,
         'truck', t.id
    from public.trucks t
    left join lateral (
      select max(vs.ts) as last_ts
        from public.eld_vehicles ev
        join public.eld_vehicle_status vs on vs.vehicle_id = ev.vehicle_id
       where ev.truck_id = t.id and ev.active
    ) le on true
   where t.status <> 'retired'
     and (le.last_ts is null or le.last_ts < now() - interval '48 hours')
     -- grace ONLY for a truly new truck with no ELD ever linked (installation
     -- pending) - NOT for freshly-imported records: the whole fleet was
     -- imported 2026-07-16, which silently suppressed every finding on the
     -- first live run (unit 05, dark since January, included)
     and not (coalesce(t.created_at, now()) > now() - interval '7 days'
              and le.last_ts is null
              and not exists (select 1 from public.eld_vehicles ev2 where ev2.truck_id = t.id));

  -- ===== COMPLIANCE: customer authority (R8 Blocks 31/32) =====
  -- weekly QCMobile re-check results: revoked authority / out-of-service is
  -- critical (their freight bills may become uncollectable); name drift warns
  -- (number may have been reassigned or the customer re-registered).
  insert into _findings
  select 'cust_authority:'||k.customer_id, 'compliance', 'critical',
         'Customer "'||c.company_name||'" authority problem (FMCSA)',
         'FMCSA says allowed-to-operate = '''||k.allowed_to_operate||''''
           ||coalesce(', out-of-service since '||to_char(k.oos_date,'Mon DD YYYY'),'')
           ||' for USDOT '||coalesce(nullif(k.usdot,''),'?')||' / MC '||coalesce(nullif(k.mc,''),'?')
           ||'. Re-verify before extending more credit; open AR may be at risk.',
         'customer', k.customer_id
    from public.customer_fmcsa_checks k
    join public.customers c on c.id = k.customer_id
   where coalesce(c.do_not_use, false) = false
     and (k.allowed_to_operate = 'N' or k.oos_date is not null);

  insert into _findings
  select 'cust_fmcsa_drift:'||k.customer_id, 'compliance', 'warn',
         'Customer "'||c.company_name||'" no longer matches its FMCSA record',
         'FMCSA now returns "'||k.legal_name||'" for USDOT '||coalesce(nullif(k.usdot,''),'?')
           ||' - the number may have been reassigned or the company renamed. Verify and update the customer record.',
         'customer', k.customer_id
    from public.customer_fmcsa_checks k
    join public.customers c on c.id = k.customer_id
   where coalesce(c.do_not_use, false) = false
     and k.name_match is false;

  -- (R8) Toll double-charge: same truck/agency/exit plaza, same charge,
  -- within 10 minutes -- toll agencies really do double-post transponder
  -- reads. Dedup key pins the earlier row so each pair alerts once.
  insert into _findings
  select 'toll_double:'||a.id, 'money', 'warn',
         'Possible double toll charge on truck '||coalesce(t.unit_number, a.vehicle_number, '?'),
         coalesce(a.toll_agency_name,'?')||' '||coalesce(a.exit_plaza_name, a.exit_plaza_code, '?')
           ||' posted $'||a.toll_charge::text||' twice within 10 min ('
           ||to_char(a.exit_date_time, 'MM/DD HH24:MI')||' and '||to_char(b.exit_date_time, 'MM/DD HH24:MI')
           ||'). Worth a dispute if confirmed.',
         'truck', a.truck_id
    from public.toll_transactions a
    join public.toll_transactions b
      on b.id <> a.id and b.id > a.id
     and coalesce(b.truck_id, -1) = coalesce(a.truck_id, -1)
     and coalesce(b.vehicle_number, '') = coalesce(a.vehicle_number, '')
     and coalesce(b.toll_agency_name, '') = coalesce(a.toll_agency_name, '')
     and coalesce(b.exit_plaza_code, b.exit_plaza_name, '') = coalesce(a.exit_plaza_code, a.exit_plaza_name, '')
     and b.toll_charge = a.toll_charge
     and b.exit_date_time >= a.exit_date_time
     and b.exit_date_time <= a.exit_date_time + interval '10 minutes'
    left join public.trucks t on t.id = a.truck_id
   where a.toll_charge > 0
     and a.exit_date_time > now() - interval '45 days'
     and coalesce(a.dispute_status, '') not ilike '%disput%';

  -- (R9 #14/15/24) Credential expiry ladder: CDL, medical card, plates.
  -- One dedup key per credential+window so escalation re-alerts as the date
  -- approaches (60d info -> 30d warn -> 7d/expired critical).
  insert into _findings
  select 'cred:'||src.kind||':'||src.key_id||':'||src.stage, 'compliance',
         case src.stage when '60d' then 'info' when '30d' then 'warn' else 'critical' end,
         src.title, src.detail, src.etype, src.key_id
  from (
    select 'cdl' as kind, d.id as key_id, 'driver' as etype,
           case when d.license_expiration < current_date then 'expired'
                when d.license_expiration <= current_date + 7 then '7d'
                when d.license_expiration <= current_date + 30 then '30d'
                else '60d' end as stage,
           'CDL '||case when d.license_expiration < current_date then 'EXPIRED' else 'expiring' end
             ||' - '||d.full_name as title,
           d.full_name||'''s CDL '||case when d.license_expiration < current_date
             then 'expired '||to_char(d.license_expiration,'MM/DD/YYYY')||'. They cannot legally drive.'
             else 'expires '||to_char(d.license_expiration,'MM/DD/YYYY')||'. Schedule the renewal now.' end as detail
      from public.drivers d
     where d.status = 'active' and d.license_expiration is not null
       and d.license_expiration <= current_date + 60
    union all
    select 'medcard', d.id, 'driver',
           case when d.medical_card_expiry < current_date then 'expired'
                when d.medical_card_expiry <= current_date + 7 then '7d'
                when d.medical_card_expiry <= current_date + 30 then '30d'
                else '60d' end,
           'Medical card '||case when d.medical_card_expiry < current_date then 'EXPIRED' else 'expiring' end
             ||' - '||d.full_name,
           d.full_name||'''s DOT medical card '||case when d.medical_card_expiry < current_date
             then 'expired '||to_char(d.medical_card_expiry,'MM/DD/YYYY')||'. Driving without one is an OOS violation.'
             else 'expires '||to_char(d.medical_card_expiry,'MM/DD/YYYY')||'. Book the physical.' end
      from public.drivers d
     where d.status = 'active' and d.medical_card_expiry is not null
       and d.medical_card_expiry <= current_date + 60
    union all
    select 'plate', t.id, 'truck',
           case when t.plate_expiry < current_date then 'expired'
                when t.plate_expiry <= current_date + 7 then '7d'
                when t.plate_expiry <= current_date + 30 then '30d'
                else '60d' end,
           'Plate '||case when t.plate_expiry < current_date then 'EXPIRED' else 'expiring' end
             ||' - truck '||t.unit_number,
           'Truck '||t.unit_number||' plate '||coalesce(t.plate_number,'?')||' '
             ||case when t.plate_expiry < current_date
               then 'expired '||to_char(t.plate_expiry,'MM/DD/YYYY')||'.'
               else 'expires '||to_char(t.plate_expiry,'MM/DD/YYYY')||'.' end
      from public.trucks t
     where t.status <> 'retired' and t.plate_expiry is not null
       and t.plate_expiry <= current_date + 60
  ) src;

  -- (R9 #18/19) Annual DOT inspection: every truck needs one every 365 days
  -- (49 CFR 396.17). Keys off completed dot_inspection maintenance records;
  -- warns 30d out, critical once overdue or never recorded.
  insert into _findings
  select 'annual_insp:'||t.id||case when li.last is null then ':none'
           when li.last < current_date - 365 then ':overdue' else ':due' end,
         'compliance',
         case when li.last is null or li.last < current_date - 365 then 'critical' else 'warn' end,
         'Annual DOT inspection '||case when li.last is null then 'NOT ON RECORD'
           when li.last < current_date - 365 then 'OVERDUE' else 'due soon' end
           ||' - truck '||t.unit_number,
         case when li.last is null
           then 'Truck '||t.unit_number||' has no completed DOT inspection in maintenance records. If one was done on paper, enter it (service type: DOT Inspection); if not, schedule it - operating without a current annual is an OOS violation.'
           else 'Truck '||t.unit_number||' last annual: '||to_char(li.last,'MM/DD/YYYY')
             ||' ('||(current_date - li.last)::text||' days ago). Due by '||to_char(li.last + 365,'MM/DD/YYYY')||'.' end,
         'truck', t.id
    from public.trucks t
    left join lateral (
      select max(m.date_completed) as last from public.maintenance_records m
       where m.truck_id = t.id and m.status = 'completed' and m.service_type = 'dot_inspection'
    ) li on true
   where t.status <> 'retired'
     and (li.last is null or li.last < current_date - 335);

  -- (R9 #20/21/28) Driver compliance program: MVR annual review (49 CFR
  -- 391.25), random drug/alcohol testing pool enrollment (part 382), and the
  -- annual Clearinghouse limited query (382.701(b)). These are records
  -- violations, not out-of-service conditions -> warn, not critical.
  insert into _findings
  select 'mvr:'||d.id||case when le.last is null then ':none' else ':overdue' end,
         'compliance', 'warn',
         'Annual MVR review '||case when le.last is null then 'not on record' else 'overdue' end
           ||' - '||d.full_name,
         case when le.last is null
           then d.full_name||' has no MVR review on record. 49 CFR 391.25 requires reviewing each driver''s motor vehicle record every 12 months - pull the MVR and log it under Compliance log on the Drivers page.'
           else d.full_name||'''s last MVR review was '||to_char(le.last,'MM/DD/YYYY')||' ('||(current_date-le.last)::text||' days ago). Pull a fresh MVR and log the review.' end,
         'driver', d.id
    from public.drivers d
    left join lateral (select max(e.occurred_on) as last from public.driver_compliance_events e
       where e.driver_id = d.id and e.kind = 'mvr_review') le on true
   where d.status = 'active' and (le.last is null or le.last < current_date - 365);

  insert into _findings
  select 'drugpool:'||d.id, 'compliance', 'warn',
         'Drug/alcohol pool enrollment not on record - '||d.full_name,
         d.full_name||' has no random drug/alcohol testing pool enrollment on record (49 CFR part 382). If they are enrolled through a consortium, enter the consortium name and enrollment date on the driver form; if not, enroll them.',
         'driver', d.id
    from public.drivers d
   where d.status = 'active' and d.drug_pool_enrolled_on is null;

  insert into _findings
  select 'clearinghouse:'||d.id||case when le.last is null then ':none' else ':overdue' end,
         'compliance', 'warn',
         'Clearinghouse annual query '||case when le.last is null then 'not on record' else 'overdue' end
           ||' - '||d.full_name,
         case when le.last is null
           then 'No FMCSA Clearinghouse query on record for '||d.full_name||'. 49 CFR 382.701(b) requires at least a limited query annually for every CDL driver - run it at clearinghouse.fmcsa.dot.gov and log it under Compliance log.'
           else 'Last Clearinghouse query for '||d.full_name||' was '||to_char(le.last,'MM/DD/YYYY')||' - the annual query is due. Run it and log it.' end,
         'driver', d.id
    from public.drivers d
    left join lateral (select max(e.occurred_on) as last from public.driver_compliance_events e
       where e.driver_id = d.id and e.kind = 'clearinghouse_query') le on true
   where d.status = 'active' and (le.last is null or le.last < current_date - 365);

  -- (R9 #31) Fee-sliver aging: factored fee residuals still on the books 90+
  -- days after factoring mean the write-off packet isn't reaching QBO. One
  -- aggregate nag that resolves itself when the books get cleaned.
  insert into _findings
  select 'sliver_aging', 'money', 'warn',
         s.n||' factoring-fee slivers 90+ days old ($'||s.amt||')',
         s.n||' settled invoices 90+ days old still show their factoring fee as an open balance ($'||s.amt||' total). Approve them on the Invoices > Factoring tab and hand the packet to the accountant - until QBO clears them, aging reports stay polluted.',
         '', null
    from (select count(*) n, round(sum(i.qbo_balance), 2) amt
            from public.invoices i
           where i.factored_at is not null and i.status = 'sent' and i.source = 'qbo'
             and i.qbo_balance > 0 and i.qbo_balance <= least(0.15 * i.total, 500)
             and i.invoice_date < current_date - 90) s
   where s.n > 0;

  -- (R9 #39) Budget discipline: a cost line 20%+ over budget two months
  -- running is a trend, not a blip. Fires per line, resolves when either
  -- month comes back inside (or the budget gets fixed).
  declare
    v_bm1 date := (date_trunc('month', current_date) - interval '1 month')::date;
    v_bm2 date := (date_trunc('month', current_date) - interval '2 months')::date;
    v_p1 jsonb := public.pnl_summary(v_bm1::timestamptz, (v_bm1 + interval '1 month')::timestamptz);
    v_p2 jsonb := public.pnl_summary(v_bm2::timestamptz, (v_bm2 + interval '1 month')::timestamptz);
    v_key text;
    v_pk text;
  begin
    for v_key, v_pk in select * from (values
      ('fuel','fuel_cost'), ('tolls','toll_cost'), ('driver_pay','driver_pay'),
      ('maintenance','maintenance_cost'), ('truck_fixed','truck_fixed_cost')) t
    loop
      insert into _findings
      select 'budget_over:'||v_key, 'money', 'warn',
             initcap(replace(v_key,'_',' '))||' over budget 2 months running',
             initcap(replace(v_key,'_',' '))||' ran $'||round((v_p1->>v_pk)::numeric)
               ||' against a $'||round(b1.amount)||' budget in '||to_char(v_bm1,'Mon')
               ||' and $'||round((v_p2->>v_pk)::numeric)||' against $'||round(b2.amount)
               ||' in '||to_char(v_bm2,'Mon')||' - both 20%+ over. Chase the line or fix the budget.',
             '', null
        from budgets b1, budgets b2
       where b1.period_month = v_bm1 and b1.line = v_key and b1.amount > 0
         and b2.period_month = v_bm2 and b2.line = v_key and b2.amount > 0
         and (v_p1->>v_pk)::numeric > b1.amount * 1.2
         and (v_p2->>v_pk)::numeric > b2.amount * 1.2;
    end loop;
  end;

  -- (R9 #77) Invoices drafted then forgotten: a draft older than 48h is
  -- either ready to send or shouldn't exist.
  insert into _findings
  select 'stale_drafts', 'cash', 'warn',
         s.n||' invoice draft'||case when s.n=1 then '' else 's' end||' sitting unsent 48h+',
         s.n||' draft invoice'||case when s.n=1 then '' else 's' end||' ($'||s.amt||') created 48h+ ago and never sent. Send them or void them - drafts do not collect.',
         '', null
    from (select count(*) n, round(coalesce(sum(total),0),2) amt from public.invoices
           where status = 'draft' and created_at < now() - interval '48 hours') s
   where s.n > 0;

  -- (R9 #78) The proof is on file but the bill never went out: delivered load
  -- with a POD attached, 72h+, still not invoiced.
  insert into _findings
  select 'pod_uninvoiced', 'cash', 'warn',
         s.n||' load'||case when s.n=1 then '' else 's' end||' with a POD on file, still uninvoiced 72h+',
         'The paperwork is done: '||s.n||' delivered load'||case when s.n=1 then '' else 's' end||' ($'||s.amt||') have a POD attached but no invoice 72h+ after delivery. Bill them from the Unbilled tab.',
         '', null
    from (select count(*) n, round(coalesce(sum(l.rate),0),2) amt from public.loads l
           where l.status = 'completed' and l.invoice_id is null
             and l.delivery_time < now() - interval '72 hours'
             and exists (select 1 from public.documents doc
                          where doc.entity_type = 'load' and doc.entity_id = l.id
                            and doc.doc_type ilike 'pod')) s
   where s.n > 0;

  -- (R9 #80) Fuel bought on a day the ELD says the truck never moved - while
  -- the ELD demonstrably works on other days. Card in someone's pocket?
  insert into _findings
  select 'fuel_darkday:'||f.truck_id||':'||f.d, 'money', 'warn',
         'Fuel on a no-mileage day - truck '||t.unit_number,
         'Truck '||t.unit_number||' bought $'||f.amt||' of fuel on '||to_char(f.d,'MM/DD')||' but its ELD logged no miles that day (and reported fine on other recent days). Ask who fueled what.',
         'truck', f.truck_id
    from (select ft.truck_id, ft.transaction_time::date d,
                 round(sum(coalesce(ft.net_of_discount, ft.amount)),2) amt
            from public.fuel_transactions ft
           where ft.truck_id is not null and ft.transaction_time > now() - interval '7 days'
           group by ft.truck_id, ft.transaction_time::date) f
    join public.trucks t on t.id = f.truck_id
   where f.d < current_date - 1  -- today/yesterday may simply not be banked yet
     and not exists (select 1 from public.eld_daily_miles em
                      where em.truck_id = f.truck_id and em.day = f.d and em.miles > 1)
     -- the bank must have covered BOTH adjacent days, or a missing row just
     -- means the daily-miles job skipped a day (known gaps), not a parked truck
     and exists (select 1 from public.eld_daily_miles ea
                  where ea.truck_id = f.truck_id and ea.day = f.d - 1 and ea.miles > 1)
     and exists (select 1 from public.eld_daily_miles eb
                  where eb.truck_id = f.truck_id and eb.day = f.d + 1 and eb.miles > 1);

  -- (R9 #81) Toll charged while the ELD says the truck sat still: the
  -- transponder may be riding in another vehicle.
  insert into _findings
  select 'toll_notruck:'||x.truck_id||':'||x.d, 'money', 'warn',
         'Toll on a no-mileage day - truck '||t.unit_number,
         'Truck '||t.unit_number||' was charged $'||x.amt||' in tolls on '||to_char(x.d,'MM/DD')||' but its ELD logged no movement that day. Check where that transponder actually is.',
         'truck', x.truck_id
    from (select tt.truck_id, tt.exit_date_time::date d, round(sum(tt.toll_charge),2) amt
            from public.toll_transactions tt
           where tt.truck_id is not null and tt.exit_date_time > now() - interval '7 days'
           group by tt.truck_id, tt.exit_date_time::date) x
    join public.trucks t on t.id = x.truck_id
   where x.d < current_date - 1
     and not exists (select 1 from public.eld_daily_miles em
                      where em.truck_id = x.truck_id and em.day = x.d and em.miles > 1)
     and exists (select 1 from public.eld_daily_miles ea
                  where ea.truck_id = x.truck_id and ea.day = x.d - 1 and ea.miles > 1)
     and exists (select 1 from public.eld_daily_miles eb
                  where eb.truck_id = x.truck_id and eb.day = x.d + 1 and eb.miles > 1);

  -- (R9 #82) Same-day duplicate load entry: same broker, same day, same
  -- addresses, same rate - almost certainly keyed twice.
  insert into _findings
  select 'dup_load:'||min(l.id)||':'||max(l.id), 'ops', 'warn',
         'Possible duplicate load entry',
         count(*)||' loads for the same customer with identical pickup/delivery/rate on '
           ||to_char(l.pickup_time::date,'MM/DD')||' (loads #'||string_agg(l.id::text, ', #' order by l.id)||'). If one is a double entry, cancel it before it double-bills.',
         'load', min(l.id)
    from public.loads l
   where l.status not in ('cancelled') and l.pickup_time > now() - interval '14 days'
   group by l.customer_id, l.pickup_time::date, l.pickup_address, l.delivery_address, l.rate
  having count(*) > 1;

  -- (R9 #84) QBO mirror drift: the 30-min sync erroring or silent for 2h+
  -- means every AR number on screen is going stale.
  insert into _findings
  select 'qbo_sync_stale', 'ops', 'warn',
         'QBO sync '||case when q.last_error is not null then 'erroring' else 'silent 2h+' end,
         'The QuickBooks mirror last pulled '||coalesce(to_char(q.last_pull_at,'MM/DD HH24:MI'),'never')
           ||case when q.last_error is not null then ' and reported: '||left(q.last_error,180) else '' end
           ||'. Until it recovers, AR/aging/GL numbers are stale.',
         '', null
    from public.qbo_sync_state q
   where q.id = 1
     and (q.last_error is not null or q.last_pull_at < now() - interval '2 hours');

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

  -- (R9 #88) findings from OTHER producers (watchdog, shadow, hygiene jobs)
  -- that nothing has refreshed in 30 days are stale, not open: close them so
  -- the feed stays a to-do list instead of a landfill.
  update public.trux_insights set status = 'resolved', resolved_at = now()
   where status = 'open' and last_seen < now() - interval '30 days';

  return jsonb_build_object(
    'fired', fired, 'resolved', resolved,
    'open', (select count(*) from public.trux_insights where status <> 'resolved'),
    'critical', (select count(*) from public.trux_insights where status <> 'resolved' and severity = 'critical'));
end;
$function$;

-- sentinel_take_alerts: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.sentinel_take_alerts()
 RETURNS SETOF trux_insights
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() = 'admin') then
    raise exception 'Not enough permissions';
  end if;
  return query
  update public.trux_insights
     set notified_at = now()
   where status = 'open' and severity = 'critical' and notified_at is null
     and (snoozed_until is null or snoozed_until < now())
  returning *;
end; $function$;

-- set_lockdown: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.set_lockdown(p_on boolean, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or coalesce(public.my_role()::text,'none') = 'admin') then
    raise exception 'Not enough permissions';
  end if;
  update app_private.system_flags set value = case when p_on then 'on' else 'off' end,
         updated_at = now() where key = 'lockdown';
  perform app_private.audit('lockdown_' || case when p_on then 'engaged' else 'lifted' end,
    'critical', jsonb_build_object('reason', p_reason));
  return jsonb_build_object('lockdown', p_on);
end;
$function$;

-- stop_dwell_summary: 1 gate(s) converted
CREATE OR REPLACE FUNCTION public.stop_dwell_summary(p_days integer DEFAULT 45, p_radius_mi numeric DEFAULT 0.75)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare pu_avg numeric; de_avg numeric; pu_n int; de_n int;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with stops as (
    select l.id as load_id, 'pickup'::text as stop_type, l.pickup_time as appt,
           l.pickup_lat as lat, l.pickup_lon as lon, l.truck_id
      from public.loads l
     where l.truck_id is not null and l.pickup_lat is not null and l.pickup_time is not null
       and l.delivery_time > now() - make_interval(days => p_days)
    union all
    select l.id, 'delivery', l.delivery_time, l.delivery_lat, l.delivery_lon, l.truck_id
      from public.loads l
     where l.truck_id is not null and l.delivery_lat is not null and l.delivery_time is not null
       and l.delivery_time > now() - make_interval(days => p_days)
  ),
  dwell as (
    select s.stop_type,
           (select min(h.ts) from public.eld_location_history h
             where h.truck_id = s.truck_id
               and h.ts between s.appt - interval '18 hours' and s.appt + interval '18 hours'
               and public.trux_miles(s.lat, s.lon, h.lat, h.lng) <= p_radius_mi) as arr,
           (select max(h.ts) from public.eld_location_history h
             where h.truck_id = s.truck_id
               and h.ts between s.appt - interval '18 hours' and s.appt + interval '18 hours'
               and public.trux_miles(s.lat, s.lon, h.lat, h.lng) <= p_radius_mi) as dep
      from stops s
  ),
  m as (
    select stop_type, extract(epoch from (dep - arr)) / 3600.0 as hrs
      from dwell where arr is not null and dep is not null and dep > arr
  )
  select round(avg(hrs) filter (where stop_type='pickup'), 1),
         round(avg(hrs) filter (where stop_type='delivery'), 1),
         count(*) filter (where stop_type='pickup'),
         count(*) filter (where stop_type='delivery')
    into pu_avg, de_avg, pu_n, de_n from m;

  return jsonb_build_object(
    'avg_dwell_hours_shipper', pu_avg, 'stops_measured_shipper', coalesce(pu_n,0),
    'avg_dwell_hours_consignee', de_avg, 'stops_measured_consignee', coalesce(de_n,0));
end;
$function$;

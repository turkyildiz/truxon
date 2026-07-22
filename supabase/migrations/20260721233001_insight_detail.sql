-- Click-through detail for a Sentinel finding: the underlying evidence records
-- (fuel-card transactions, toll, etc. — truck, date/time, driver, card, amount)
-- PLUS a plain-English "why Forest flagged this" so the team can investigate.
-- Office-gated, read-only, fail-closed on a null role.
create or replace function public.insight_detail(p_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  ins       public.trux_insights;
  prefix    text;
  subject   text;
  why       text;
  records   jsonb := '[]'::jsonb;
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') not in ('admin','accountant','dispatcher') then
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
$$;

revoke execute on function public.insight_detail(bigint) from public, anon;
grant execute on function public.insight_detail(bigint) to authenticated, service_role;

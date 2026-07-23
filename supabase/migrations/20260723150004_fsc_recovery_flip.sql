-- R9 Section G (chained off #104): fuel-surcharge playbook flips #14 + #69.
-- The rate-con line items finally give surcharge REVENUE a source; fuel
-- spend comes from the AtoB import. Coverage is stated, not hidden: FSC only
-- exists for loads whose rate con was scanned, and the fuel `amount` field is
-- known-dirty (see fuel-theft notes) so spend prefers net_of_discount.
create or replace function public.fuel_surcharge_recovery(p_days int default 90)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when coalesce(auth.role(), '') = 'service_role'
              or public.my_role() in ('admin','accountant','dispatcher')
  then (
    with fsc as (
      select coalesce(sum(li.amount), 0) as captured,
             count(distinct li.load_id)  as loads_with_fsc
      from load_line_items li
      join loads l on l.id = li.load_id
      where li.kind = 'fuel_surcharge'
        and l.created_at > now() - make_interval(days => p_days)
    ),
    cover as (
      select count(*) as loads_total,
             count(*) filter (where exists
               (select 1 from load_line_items li where li.load_id = l.id)) as loads_extracted
      from loads l where l.created_at > now() - make_interval(days => p_days)
    ),
    spend as (
      select coalesce(sum(coalesce(net_of_discount, amount)), 0) as fuel_cost
      from fuel_transactions
      where transaction_time > now() - make_interval(days => p_days)
    )
    select jsonb_build_object(
      'days', p_days,
      'fsc_captured', fsc.captured,
      'loads_with_fsc', fsc.loads_with_fsc,
      'loads_extracted', cover.loads_extracted,
      'loads_total', cover.loads_total,
      'fuel_spend', spend.fuel_cost,
      'recovery_pct', case when spend.fuel_cost = 0 then null
        else round(100.0 * fsc.captured / spend.fuel_cost, 1) end,
      'note', 'FSC exists only for scanned rate cons ('||cover.loads_extracted||'/'||cover.loads_total
        ||' loads extracted); spend prefers net_of_discount over the dirty amount field',
      'as_of', now())
    from fsc, cover, spend)
  end;
$$;
revoke all on function public.fuel_surcharge_recovery(int) from public, anon;
grant execute on function public.fuel_surcharge_recovery(int) to authenticated, service_role;

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'fuel_surcharge_recovery(days) fsc_captured — sum of fuel_surcharge line items from scanned rate cons (coverage stated in the payload)'
where number = 14 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'fuel_surcharge_recovery(days) recovery_pct — FSC captured ÷ fuel spend (net_of_discount preferred); coverage-limited to extracted rate cons'
where number = 69 and status <> 'live';

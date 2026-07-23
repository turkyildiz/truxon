-- R9 #105: rate-con ↔ load reconciliation + fuel-surcharge capture summary.
-- One admin/office report RPC: which loads' extracted line-item totals
-- disagree with the booked rate (typo, missed accessorial, short-paid
-- surcharge), plus the surcharge-capture stats the playbook flip needs.
-- Coverage is reported honestly: loads with no line items are "not_extracted",
-- never counted as clean.
create or replace function public.ratecon_recon_report(p_days int default 90)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with scoped as (
    select l.id, l.load_number, l.rate, l.created_at
    from loads l
    where l.created_at > now() - make_interval(days => p_days)
  ),
  items as (
    select li.load_id,
           sum(li.amount) as extracted_total,
           sum(li.amount) filter (where li.kind = 'fuel_surcharge') as fuel_surcharge,
           sum(li.amount) filter (where li.kind not in ('line_haul','fuel_surcharge')) as accessorials,
           count(*) as n_items
    from load_line_items li
    join scoped s on s.id = li.load_id
    group by li.load_id
  ),
  joined as (
    select s.*, i.extracted_total, i.fuel_surcharge, i.accessorials, i.n_items,
           (i.load_id is not null)                                  as extracted,
           (i.load_id is not null
             and abs(coalesce(i.extracted_total,0) - coalesce(s.rate,0)) > 1.00) as mismatch
    from scoped s left join items i on i.load_id = s.id
  )
  select jsonb_build_object(
    'days', p_days,
    'loads', (select count(*) from joined),
    'extracted', (select count(*) from joined where extracted),
    'not_extracted', (select count(*) from joined where not extracted),
    'mismatches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'load_id', id, 'load_number', load_number,
        'booked_rate', rate, 'extracted_total', extracted_total,
        'delta', round(extracted_total - coalesce(rate,0), 2), 'items', n_items)
        order by abs(extracted_total - coalesce(rate,0)) desc)
      from joined where mismatch), '[]'::jsonb),
    'fuel_surcharge', jsonb_build_object(
      'loads_with_surcharge', (select count(*) from joined where coalesce(fuel_surcharge,0) > 0),
      'total_captured', (select coalesce(sum(fuel_surcharge),0) from joined),
      'pct_of_extracted_revenue', (
        select case when coalesce(sum(extracted_total),0) = 0 then null
          else round(100.0 * coalesce(sum(fuel_surcharge),0) / sum(extracted_total), 2) end
        from joined where extracted)),
    'accessorials_total', (select coalesce(sum(accessorials),0) from joined)
  );
$$;
revoke all on function public.ratecon_recon_report(int) from public, anon;
grant execute on function public.ratecon_recon_report(int) to authenticated, service_role;

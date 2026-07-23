-- R9 #44: straight-line depreciation schedule from the purchase data on the
-- equipment forms — books-independent (the accountant's MACRS is theirs; this
-- is the owner's honest asset view). Assumptions stated in the output:
-- 60-month life, 20% salvage. Empty until purchase price+date are entered.
create or replace function public.depreciation_schedule()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when auth.role() = 'service_role' or public.my_role() in ('admin','accountant')
  then jsonb_build_object(
    'assumptions', '60-month straight line, 20% salvage — owner view, not the tax books',
    'entered', (select count(*) from trucks where status <> 'retired'
                 and purchase_price > 0 and purchase_date is not null),
    'trucks_total', (select count(*) from trucks where status <> 'retired'),
    'monthly_depreciation_total', coalesce((select round(sum(t.purchase_price * 0.8 / 60), 2)
      from trucks t where t.status <> 'retired' and t.purchase_price > 0 and t.purchase_date is not null
        and t.purchase_date + interval '60 months' > now()), 0),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'unit', t.unit_number,
        'purchase_price', t.purchase_price,
        'purchase_date', t.purchase_date,
        'monthly', round(t.purchase_price * 0.8 / 60, 2),
        'months_elapsed', least(60, greatest(0,
          (extract(year from age(now(), t.purchase_date)) * 12
           + extract(month from age(now(), t.purchase_date)))::int)),
        'book_value', round(t.purchase_price
          - t.purchase_price * 0.8 / 60 * least(60, greatest(0,
              (extract(year from age(now(), t.purchase_date)) * 12
               + extract(month from age(now(), t.purchase_date)))::int)), 2))
        order by t.unit_number)
      from trucks t
      where t.status <> 'retired' and t.purchase_price > 0 and t.purchase_date is not null), '[]'::jsonb),
    'as_of', now())
  end;
$$;
revoke all on function public.depreciation_schedule() from public, anon;
grant execute on function public.depreciation_schedule() to authenticated, service_role;

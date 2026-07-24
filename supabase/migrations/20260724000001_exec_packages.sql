-- R9 #170/#171: two external-party export packages. Both ASSEMBLE existing,
-- already-audited primitives (P&L mirror, balance ratios, AR march, IFTA fuel
-- rollup, depreciation) into one payload — no new numbers are invented, and
-- each package names its own gaps so nobody mistakes it for a filed return.
-- #170 banker_package: financials + ratios + the fleet list a lender asks for.
create or replace function public.banker_package(p_months int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  -- gl_pnl_monthly is admin-only; keep the whole package there so it never
  -- half-fails inside on an accountant login.
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() = 'admin') then
    raise exception 'Not enough permissions';
  end if;
  select jsonb_build_object(
    'generated_for', 'lender / credit review',
    'months', p_months,
    'pnl_monthly', coalesce((select jsonb_agg(to_jsonb(p)) from public.gl_pnl_monthly(p_months) p), '[]'::jsonb),
    'balance_ratios', public.gl_balance_ratios(),
    'receivables', public.finance_march(),
    'fleet', jsonb_build_object(
      'power_units', (select count(*) from trucks where status <> 'retired'),
      'trailers', (select count(*) from trailers where status <> 'retired'),
      'trucks', coalesce((select jsonb_agg(jsonb_build_object(
          'unit', t.unit_number, 'year', t.year, 'make', t.make, 'model', t.model,
          'vin', t.vin, 'plate', t.plate_number,
          'purchase_price', t.purchase_price, 'purchase_date', t.purchase_date)
          order by t.unit_number)
        from trucks t where t.status <> 'retired'), '[]'::jsonb)),
    'note', 'assembled from the QuickBooks mirror and fleet records — an underwriting worksheet, not audited statements',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.banker_package(int) from public, anon, authenticated;
grant execute on function public.banker_package(int) to authenticated, service_role;

-- #171 tax_season_package: everything the accountant re-keys at tax time —
-- IFTA fuel by state per quarter, the 2290 (HVUT) power-unit list, and the
-- owner-view depreciation schedule. Calendar year.
create or replace function public.tax_season_package(p_year int)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
  q jsonb := '[]'::jsonb;
  i int;
  qs timestamptz; qe timestamptz;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  -- IFTA fuel purchases by jurisdiction, one block per calendar quarter.
  for i in 1..4 loop
    qs := make_timestamptz(p_year, (i - 1) * 3 + 1, 1, 0, 0, 0);
    qe := qs + interval '3 months';
    q := q || jsonb_build_object(
      'quarter', 'Q' || i,
      'by_state', coalesce((select jsonb_agg(to_jsonb(s)) from public.fuel_ifta_summary(qs, qe) s), '[]'::jsonb));
  end loop;

  select jsonb_build_object(
    'tax_year', p_year,
    'generated_for', 'accountant / tax prep',
    'ifta_fuel_by_quarter', q,
    'hvut_2290', jsonb_build_object(
      'note', 'all non-retired power units — confirm taxable gross weight (55,000 lb+ files Form 2290); weight is not tracked in Truxon',
      'units', coalesce((select jsonb_agg(jsonb_build_object(
          'unit', t.unit_number, 'year', t.year, 'make', t.make, 'model', t.model,
          'vin', t.vin, 'purchase_date', t.purchase_date)
          order by t.unit_number)
        from trucks t where t.status <> 'retired'), '[]'::jsonb)),
    'depreciation', public.depreciation_schedule(),
    'note', 'IFTA shows FUEL PURCHASED by state (from fuel-card data), not taxable miles by state — pair with the mileage rollup; nothing here is a filed return',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.tax_season_package(int) from public, anon, authenticated;
grant execute on function public.tax_season_package(int) to authenticated, service_role;

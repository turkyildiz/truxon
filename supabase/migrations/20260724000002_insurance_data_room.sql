-- R9 #169: insurance-renewal data room. One export with what an underwriter's
-- renewal application actually asks for: the carrier's identity + FMCSA safety
-- profile, a trailing-12-month loss/exposure summary, the driver roster (age +
-- experience + credential currency), and the power-unit/trailer schedule. Like
-- the other packages it ONLY assembles audited primitives and names its gaps —
-- driver MVR/CDL-class detail and stated values are not in Truxon.
create or replace function public.insurance_data_room(p_months int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
  cs company_settings;
  win_start timestamptz := now() - make_interval(months => greatest(p_months, 1));
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select * into cs from company_settings where id = 1;

  select jsonb_build_object(
    'generated_for', 'insurance renewal / underwriting',
    'window_months', p_months,
    'carrier', jsonb_build_object(
      'name', cs.company_name, 'usdot', cs.usdot_number, 'mc', cs.mc_number,
      'address', cs.address, 'phone', cs.phone),
    'safety_profile', public.carrier_safety_latest(),
    'loss_experience', public.safety_summary(win_start, now()),
    'drivers', jsonb_build_object(
      'active', (select count(*) from drivers where status = 'active'),
      'roster', coalesce((select jsonb_agg(jsonb_build_object(
          'name', d.full_name,
          'age', case when d.date_of_birth is not null
                      then extract(year from age(now(), d.date_of_birth))::int end,
          'years_experience', case when d.hire_date is not null
                      then round(extract(epoch from age(now(), d.hire_date)) / 31557600.0, 1) end,
          'cdl_expires', d.license_expiration,
          'med_card_expires', d.medical_card_expiry,
          'credentials_current', (d.license_expiration is null or d.license_expiration >= current_date)
                              and (d.medical_card_expiry is null or d.medical_card_expiry >= current_date))
          order by d.full_name)
        from drivers d where d.status = 'active'), '[]'::jsonb)),
    'equipment', jsonb_build_object(
      'power_units', (select count(*) from trucks where status <> 'retired'),
      'trailers', (select count(*) from trailers where status <> 'retired'),
      'schedule', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('type', 'power_unit', 'unit', unit_number,
                 'year', year, 'make', make, 'model', model, 'vin', vin,
                 'stated_value', purchase_price) as x
          from trucks where status <> 'retired'
        union all
        select jsonb_build_object('type', 'trailer', 'unit', unit_number,
                 'year', year, 'make', make, 'model', model, 'vin', vin,
                 'stated_value', purchase_price)
          from trailers where status <> 'retired') s), '[]'::jsonb)),
    'note', 'assembled from Truxon records — MVR detail, CDL class/endorsements, and agreed stated values are not tracked here; stated_value shows purchase price where recorded',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.insurance_data_room(int) from public, anon, authenticated;
grant execute on function public.insurance_data_room(int) to authenticated, service_role;

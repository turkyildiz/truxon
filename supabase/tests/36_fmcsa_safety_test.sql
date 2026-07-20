-- FMCSA safety watch: fmcsa_record ingests a snapshot + BASICs, carrier_safety_latest
-- reads them back, and sentinel_scan fires a critical finding on a lost rating.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000fdca'::uuid, 'fmcsa@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000fdca';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000fdca"}', true);

-- ingest a Conditional-rated carrier with a vehicle-maintenance BASIC over threshold
select public.fmcsa_record(
  jsonb_build_object(
    'snapshot_date','2026-07-01','dot_number','1234567','legal_name','AIDA LOGISTICS LLC',
    'safety_rating','C','safety_rating_date','2026-06-15','allowed_to_operate','Y','status_code','A',
    'driver_oos_rate','3.5','driver_oos_natl','5.5','vehicle_oos_rate','28.0','vehicle_oos_natl','20.7',
    'crash_total','2','total_power_units','8'
  ),
  jsonb_build_array(
    jsonb_build_object('basic','vehicle_maint','percentile','92.0','measure','3.1','alert', true),
    jsonb_build_object('basic','unsafe_driving','percentile','40.0','measure','1.0','alert', false)
  )
);

select is((select safety_rating from public.carrier_safety_snapshot where snapshot_date='2026-07-01'), 'C', 'snapshot rating recorded');
select is((select vehicle_oos_rate from public.carrier_safety_snapshot where snapshot_date='2026-07-01'), 28.0::numeric, 'vehicle OOS rate recorded');
select is((select alert from public.safety_csa where basic='vehicle_maint'), true, 'BASIC over threshold flagged as alert');
select is((select percentile from public.safety_csa where basic='unsafe_driving'), 40.0::numeric, 'BASIC percentile upserted');
select is(public.fmcsa_rating_label('C'), 'Conditional', 'rating label maps C→Conditional');

-- re-ingesting the same snapshot_date updates, does not duplicate
select public.fmcsa_record(jsonb_build_object('snapshot_date','2026-07-01','safety_rating','U','allowed_to_operate','Y'), '[]'::jsonb);
select is((select count(*)::int from public.carrier_safety_snapshot where snapshot_date='2026-07-01'), 1, 'same snapshot_date upserts, no duplicate');
select is((select safety_rating from public.carrier_safety_snapshot where snapshot_date='2026-07-01'), 'U', 'snapshot updated in place');

-- the read helper returns the latest snapshot + basics for the card
select is(public.carrier_safety_latest()->'snapshot'->>'safety_rating', 'U', 'carrier_safety_latest returns the newest rating');

-- Sentinel fires a critical finding for the non-Satisfactory rating
select public.sentinel_scan();
select is(
  (select severity from public.trux_insights where dedup_key = 'fmcsa_rating' and status <> 'resolved'),
  'critical', 'a lost FMCSA rating fires a critical Sentinel insight'
);

select * from finish();
rollback;

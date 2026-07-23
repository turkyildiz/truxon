-- R9 #63: breakdown-ML readiness report. Northstar #4 waits on data, not
-- code — this is the weekly honest answer to "how close are we": rows banked,
-- per-feature coverage, positive labels (breakdowns actually observed in the
-- next-4-weeks window), and a stated bar for trainability (>=150 rows and
-- >=10 positives before a model is worth fitting).
create or replace function public.breakdown_ml_readiness()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_rows int; v_weeks int; v_pos int; v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select count(*), count(distinct week_start),
         count(*) filter (where breakdown_next_4w)
    into v_rows, v_weeks, v_pos from truck_weekly_features;
  select jsonb_build_object(
    'rows_banked', v_rows,
    'weeks_banked', v_weeks,
    'first_week', (select min(week_start) from truck_weekly_features),
    'positives', v_pos,
    'feature_coverage', jsonb_build_object(
      'mpg_pct', round(100.0 * count(mpg) / nullif(count(*), 0), 0),
      'idle_pct_pct', round(100.0 * count(idle_pct) / nullif(count(*), 0), 0),
      'speeding_pct', round(100.0 * count(speeding_min) / nullif(count(*), 0), 0),
      'odometer_pct', round(100.0 * count(odometer) / nullif(count(*), 0), 0)),
    'trainable', v_rows >= 150 and v_pos >= 10,
    'bar', 'trainable at >=150 rows and >=10 observed breakdowns',
    'eta_weeks', case when v_rows > 0 and v_weeks > 0
      then greatest(ceil((150 - v_rows)::numeric / (v_rows::numeric / v_weeks)), 0) end,
    'note', 'positives depend on breakdowns actually happening - the ETA covers rows, not labels; a healthy fleet delays the model and that is fine',
    'as_of', now()) into v from truck_weekly_features;
  return v;
end;
$$;
revoke all on function public.breakdown_ml_readiness() from public, anon;
grant execute on function public.breakdown_ml_readiness() to authenticated, service_role;

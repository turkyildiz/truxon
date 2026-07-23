-- R9 #89-100 (Section G start): playbook flips from the computable frontier.
-- Two small helpers + five flips, each with its true source; what can't be
-- computed stays needs_data (settlement disputes need payroll records, fuel
-- surcharge needs rate-con line items - block 104 territory).

-- Average/median tenure of ACTIVE drivers, from hire_date (months).
create or replace function public.driver_tenure_summary()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when coalesce(auth.role(), '') = 'service_role'
              or public.my_role() in ('admin','accountant','dispatcher')
  then (select jsonb_build_object(
    'drivers', count(*),
    'avg_months', round(avg(extract(epoch from age(now(), hire_date)) / 2629800)::numeric, 1),
    'median_months', round((percentile_cont(0.5) within group
        (order by extract(epoch from age(now(), hire_date)) / 2629800))::numeric, 1),
    'under_1y', count(*) filter (where hire_date > current_date - interval '1 year'),
    'y1_3', count(*) filter (where hire_date <= current_date - interval '1 year'
                               and hire_date > current_date - interval '3 years'),
    'over_3y', count(*) filter (where hire_date <= current_date - interval '3 years'),
    'no_hire_date', count(*) filter (where hire_date is null),
    'as_of', now())
   from drivers where status = 'active')
  end;
$$;
revoke all on function public.driver_tenure_summary() from public, anon;
grant execute on function public.driver_tenure_summary() to authenticated, service_role;

-- Loads booked per working day per active dispatcher (owner counts as the
-- dispatcher when no dispatcher role exists - solo shop honesty).
create or replace function public.dispatch_productivity(p_days int default 28)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when coalesce(auth.role(), '') = 'service_role'
              or public.my_role() in ('admin','accountant','dispatcher')
  then jsonb_build_object(
    'days', p_days,
    'loads_booked', (select count(*) from loads
                      where created_at > now() - make_interval(days => p_days)
                        and status <> 'cancelled'),
    'dispatchers', greatest((select count(*) from profiles
                              where role = 'dispatcher' and is_active), 1),
    'loads_per_dispatcher_day', round(
      (select count(*) from loads
        where created_at > now() - make_interval(days => p_days)
          and status <> 'cancelled')::numeric
      / greatest((select count(*) from profiles where role = 'dispatcher' and is_active), 1)
      / greatest(p_days * 5.0 / 7.0, 1), 2),
    'note', 'working days = 5/7 of the window; owner counts as dispatcher when none exists',
    'as_of', now())
  end;
$$;
revoke all on function public.dispatch_productivity(int) from public, anon;
grant execute on function public.dispatch_productivity(int) to authenticated, service_role;

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'finance_extras() detention_capture_pct + load_accessorials decided ledger — share of proposed accessorials the office approved/billed'
where number = 70 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'dispatch_productivity(days) — loads booked ÷ active dispatchers ÷ working days (owner counts as dispatcher when none exists)'
where number = 241 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'credit_memo_summary(months) — credit-memo rate as the dispute PROXY (a formal dispute log does not exist; memos are the disputes that stuck)'
where number = 434 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'driver_tenure_summary() — avg months from hire_date, active drivers'
where number = 515 and status <> 'live';

update public.playbook_metrics set status = 'live', updated_at = now(),
  source = 'driver_tenure_summary() — median months from hire_date, active drivers'
where number = 516 and status <> 'live';

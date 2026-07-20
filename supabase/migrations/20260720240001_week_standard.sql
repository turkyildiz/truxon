-- Standard week: Monday→Sunday, numbered by how many Mondays have passed since
-- Jan 1. If the year doesn't start on a Monday, the partial run from Jan 1 to the
-- first Sunday is WEEK 0. Week 1 starts on the first Monday. This makes weeks
-- comparable year-to-year: "Week 29 this year" vs "Week 29 last year" are both the
-- Nth Monday-started block, so the same set of weekdays lines up.
--
-- Everything that buckets or compares by week uses these — one source of truth.
-- All pure date math → IMMUTABLE (safe in indexes / generated columns).
--
--   trux_first_monday(year)     first Monday on/after Jan 1
--   trux_week_number(date)      0 for the partial lead-in, else 1..53
--   trux_week_year(date)        calendar year that owns the week number
--   trux_week_start(date)       Monday of the week (Jan 1 for week 0)
--   trux_week_end(date)         Sunday of the week (the Sunday before week 1, for week 0)
--   trux_week_label(date)       'YYYY-Www'  e.g. 2026-W00, 2026-W29
--   trux_week_range(year, week) -> (start, end)   for "same week last year"

create or replace function public.trux_first_monday(p_year int)
returns date language sql immutable strict as $$
  select make_date(p_year, 1, 1)
       + ((8 - extract(isodow from make_date(p_year, 1, 1))::int) % 7);
$$;

create or replace function public.trux_week_number(d date)
returns int language sql immutable strict as $$
  select case
    when d < public.trux_first_monday(extract(year from d)::int) then 0
    else 1 + ((d - public.trux_first_monday(extract(year from d)::int)) / 7)
  end;
$$;

create or replace function public.trux_week_year(d date)
returns int language sql immutable strict as $$
  select extract(year from d)::int;
$$;

create or replace function public.trux_week_start(d date)
returns date language sql immutable strict as $$
  select case
    when public.trux_week_number(d) = 0 then make_date(extract(year from d)::int, 1, 1)
    else d - (extract(isodow from d)::int - 1)   -- Monday of d's week
  end;
$$;

create or replace function public.trux_week_end(d date)
returns date language sql immutable strict as $$
  select case
    when public.trux_week_number(d) = 0
      then public.trux_first_monday(extract(year from d)::int) - 1   -- Sunday before week 1
    else public.trux_week_start(d) + 6
  end;
$$;

create or replace function public.trux_week_label(d date)
returns text language sql immutable strict as $$
  select extract(year from d)::int::text || '-W' || lpad(public.trux_week_number(d)::text, 2, '0');
$$;

-- The Monday→Sunday span for a given (year, week). Week 0 is the partial Jan-1
-- lead-in; weeks ≥1 are full 7-day blocks (the last one may spill into January).
create or replace function public.trux_week_range(p_year int, p_week int)
returns table (week_start date, week_end date)
language sql immutable strict as $$
  select
    case when p_week = 0 then make_date(p_year, 1, 1)
         else public.trux_first_monday(p_year) + (p_week - 1) * 7 end,
    case when p_week = 0 then public.trux_first_monday(p_year) - 1
         else public.trux_first_monday(p_year) + (p_week - 1) * 7 + 6 end;
$$;

-- Pure date helpers — no data exposure. Callable by app users; report RPCs that
-- use them are SECURITY DEFINER and call them as owner regardless.
revoke all on function public.trux_first_monday(int) from public, anon;
revoke all on function public.trux_week_number(date) from public, anon;
revoke all on function public.trux_week_year(date) from public, anon;
revoke all on function public.trux_week_start(date) from public, anon;
revoke all on function public.trux_week_end(date) from public, anon;
revoke all on function public.trux_week_label(date) from public, anon;
revoke all on function public.trux_week_range(int, int) from public, anon;
grant execute on function public.trux_first_monday(int) to authenticated;
grant execute on function public.trux_week_number(date) to authenticated;
grant execute on function public.trux_week_year(date) to authenticated;
grant execute on function public.trux_week_start(date) to authenticated;
grant execute on function public.trux_week_end(date) to authenticated;
grant execute on function public.trux_week_label(date) to authenticated;
grant execute on function public.trux_week_range(int, int) to authenticated;

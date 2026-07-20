-- Standard week: Monday-anchored, week 0 = partial Jan-1 lead-in, numbered by
-- Mondays-since-Jan-1, comparable year to year.
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

-- 2026: Jan 1 is a Thursday → week 0 = Jan 1–4, week 1 starts Mon Jan 5
select is(public.trux_first_monday(2026), '2026-01-05'::date, 'first Monday of 2026 is Jan 5');
select is(public.trux_week_number('2026-01-01'), 0, 'Jan 1 (Thu) is week 0');
select is(public.trux_week_number('2026-01-04'), 0, 'Jan 4 (Sun) is still week 0');
select is(public.trux_week_number('2026-01-05'), 1, 'Jan 5 (first Monday) is week 1');
select is(public.trux_week_number('2026-01-11'), 1, 'Jan 11 (Sun) is week 1');
select is(public.trux_week_number('2026-01-12'), 2, 'Jan 12 (Mon) is week 2');

-- start/end clamp week 0 to Jan 1 .. the Sunday before week 1
select is(public.trux_week_start('2026-01-03'), '2026-01-01'::date, 'week 0 starts Jan 1 (clamped)');
select is(public.trux_week_end('2026-01-03'),   '2026-01-04'::date, 'week 0 ends the Sunday before week 1');
select is(public.trux_week_start('2026-01-08'), '2026-01-05'::date, 'week 1 starts its Monday');
select is(public.trux_week_end('2026-01-08'),   '2026-01-11'::date, 'week 1 ends its Sunday');

-- Jul 20 2026 is a Monday, exactly week 29
select is(public.trux_week_number('2026-07-20'), 29, 'Jul 20 2026 is week 29');
select is(public.trux_week_start('2026-07-20'),  '2026-07-20'::date, 'week 29 starts Mon Jul 20');
select is(public.trux_week_end('2026-07-20'),    '2026-07-26'::date, 'week 29 ends Sun Jul 26');
select is(public.trux_week_label('2026-07-20'),  '2026-W29', 'label is 2026-W29');
select is(public.trux_week_label('2026-01-03'),  '2026-W00', 'week 0 label is 2026-W00');

-- same week last year: week 29 of 2025 is a clean Mon–Sun block (weekdays aligned)
select is((select week_start from public.trux_week_range(2025, 29)), '2025-07-21'::date, 'week 29 2025 starts Mon Jul 21');
select is((select week_end   from public.trux_week_range(2025, 29)), '2025-07-27'::date, 'week 29 2025 ends Sun Jul 27');
select is((select week_start from public.trux_week_range(2026, 0)),  '2026-01-01'::date, 'week 0 2026 range starts Jan 1');
select is((select week_end   from public.trux_week_range(2026, 0)),  '2026-01-04'::date, 'week 0 2026 range ends Jan 4');

-- a year that STARTS on a Monday has no week 0: 2024 Jan 1 is a Monday
select is(public.trux_week_number('2024-01-01'), 1, 'a year starting on Monday has no week 0 (Jan 1 = week 1)');

select * from finish();
rollback;

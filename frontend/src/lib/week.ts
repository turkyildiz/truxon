/**
 * Standard week — the single client-side source of truth, mirroring the SQL
 * functions in migration 20260720240001 exactly.
 *
 * Week = Monday→Sunday. Numbered by how many Mondays have passed since Jan 1.
 * If the year doesn't start on a Monday, the partial run Jan 1 → first Sunday is
 * WEEK 0; week 1 starts on the first Monday. This makes weeks comparable year to
 * year: "Week 29 this year" and "Week 29 last year" are both the Nth Monday-
 * started Mon–Sun block, so the same weekdays line up.
 *
 * All functions take/return LOCAL calendar dates (time-of-day ignored).
 */

const MS_DAY = 86_400_000

/** ISO day of week, Monday=1 … Sunday=7 (matches Postgres isodow). */
function isodow(d: Date): number {
  const g = d.getDay() // 0=Sun … 6=Sat
  return g === 0 ? 7 : g
}

function atMidnight(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate())
}

function addDays(d: Date, n: number): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n)
}

/** Whole days between two local midnights (b - a). */
function dayDiff(a: Date, b: Date): number {
  return Math.round((atMidnight(b).getTime() - atMidnight(a).getTime()) / MS_DAY)
}

/** First Monday on/after Jan 1 of the given year. */
export function firstMonday(year: number): Date {
  const jan1 = new Date(year, 0, 1)
  return addDays(jan1, (8 - isodow(jan1)) % 7)
}

/** 0 for the partial Jan-1 lead-in, else 1..53. */
export function weekNumber(d: Date): number {
  const fm = firstMonday(d.getFullYear())
  if (atMidnight(d) < fm) return 0
  return 1 + Math.floor(dayDiff(fm, d) / 7)
}

/** Calendar year that owns the week number. */
export function weekYear(d: Date): number {
  return d.getFullYear()
}

/** Monday of d's week (Jan 1 for week 0). */
export function weekStart(d: Date): Date {
  if (weekNumber(d) === 0) return new Date(d.getFullYear(), 0, 1)
  return addDays(atMidnight(d), -(isodow(d) - 1))
}

/** Sunday of d's week (the Sunday before week 1, for week 0). */
export function weekEnd(d: Date): Date {
  if (weekNumber(d) === 0) return addDays(firstMonday(d.getFullYear()), -1)
  return addDays(weekStart(d), 6)
}

/** 'YYYY-Www' — e.g. 2026-W00, 2026-W29. */
export function weekLabel(d: Date): string {
  return `${d.getFullYear()}-W${String(weekNumber(d)).padStart(2, '0')}`
}

/** Monday→Sunday span for a given (year, week). Use for "same week last year". */
export function weekRange(year: number, week: number): { start: Date; end: Date } {
  if (week === 0) return { start: new Date(year, 0, 1), end: addDays(firstMonday(year), -1) }
  const start = addDays(firstMonday(year), (week - 1) * 7)
  return { start, end: addDays(start, 6) }
}

/** Short human label for a week, e.g. "Week 29 (Jul 20–26)". */
export function weekTitle(d: Date): string {
  const s = weekStart(d)
  const e = weekEnd(d)
  const mon = (x: Date) => x.toLocaleDateString(undefined, { month: 'short' })
  const span = mon(s) === mon(e) ? `${mon(s)} ${s.getDate()}–${e.getDate()}` : `${mon(s)} ${s.getDate()}–${mon(e)} ${e.getDate()}`
  return `Week ${weekNumber(d)} (${span})`
}

// R9 #163: one dataviz system. Every chart in the app pulls its palette, grid,
// axes, and tooltip from here so they look identical and — the bug this fixes —
// respond to dark mode. The old charts hardcoded `stroke="#e2e8f0"` for the
// grid, which stayed light-grey on a dark background; the grid now rides
// `var(--line)` like the rest of the UI.
import type { ReactNode } from 'react'
import { CartesianGrid, Tooltip, XAxis, YAxis } from 'recharts'

/** Semantic palette — reference these, not raw hex, so a colour means the same
 * thing on every chart (revenue is always blue, money-in always green…). */
export const CHART = {
  revenue: '#2563eb',
  positive: '#16a34a',
  negative: '#dc2626',
  warn: '#f59e0b',
  neutral: '#64748b',
  accent: '#8b5cf6',
} as const

const AXIS_TICK = { fontSize: 12, fill: 'var(--muted)' } as const

/** Grid: horizontal only, theme-aware line colour. */
export function ChartGrid() {
  return <CartesianGrid strokeDasharray="3 3" stroke="var(--line)" vertical={false} />
}

/** X axis with the house tick styling; pass a formatter when needed. */
export function ChartXAxis(props: React.ComponentProps<typeof XAxis>) {
  return <XAxis tick={AXIS_TICK} tickLine={false} axisLine={false} {...props} />
}

export function ChartYAxis(props: React.ComponentProps<typeof YAxis>) {
  return <YAxis tick={AXIS_TICK} tickLine={false} axisLine={false} {...props} />
}

/** Tooltip themed to the surface — the recharts default is a white box that
 * is unreadable in dark mode. */
export function ChartTooltip(props: React.ComponentProps<typeof Tooltip>) {
  return (
    <Tooltip
      contentStyle={{
        background: 'var(--surface)',
        border: '1px solid var(--line)',
        borderRadius: 8,
        color: 'var(--body)',
        fontSize: 12,
      }}
      labelStyle={{ color: 'var(--muted)' }}
      itemStyle={{ color: 'var(--body)' }}
      cursor={{ fill: 'var(--surface-2)' }}
      {...props}
    />
  )
}

/** Legend dot + label, matched to the chart palette. */
export function LegendChip({ color, label }: { color: string; label: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-xs text-muted">
      <span className="h-2.5 w-2.5 rounded-full" style={{ background: color }} />
      {label}
    </span>
  )
}

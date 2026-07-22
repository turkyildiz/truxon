import { useEffect, useRef } from 'react'
import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode, SelectHTMLAttributes, TextareaHTMLAttributes } from 'react'
import { errorMessage } from '../supabase'

export function Button({ variant = 'primary', className = '', ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'primary' | 'secondary' | 'danger' }) {
  const styles = {
    primary: 'bg-brand text-brand-fg hover:bg-brand-hover shadow-sm',
    secondary: 'bg-surface text-body border border-line hover:bg-surface-2',
    danger: 'bg-red-600 text-white hover:bg-red-700 shadow-sm',
  }[variant]
  return (
    <button
      className={`rounded-xl px-4 py-2.5 text-sm font-semibold transition-colors disabled:opacity-50 disabled:cursor-not-allowed ${styles} ${className}`}
      {...props}
    />
  )
}

const CONTROL = 'w-full rounded-xl border border-line bg-surface px-3 py-2.5 text-sm text-body placeholder:text-muted focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/30'

export function Input(props: InputHTMLAttributes<HTMLInputElement>) {
  return <input {...props} className={`${CONTROL} ${props.className ?? ''}`} />
}

export function Select(props: SelectHTMLAttributes<HTMLSelectElement>) {
  return <select {...props} className={`${CONTROL} ${props.className ?? ''}`} />
}

export function Textarea(props: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea rows={3} {...props} className={`${CONTROL} ${props.className ?? ''}`} />
}

export function Field({ label, children, className = '' }: { label: string; children: ReactNode; className?: string }) {
  return (
    <label className={`block ${className}`}>
      <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">{label}</span>
      {children}
    </label>
  )
}

export function Card({ title, children, actions, className = '' }: { title?: string; children: ReactNode; actions?: ReactNode; className?: string }) {
  return (
    <div className={`rounded-2xl border border-line bg-surface p-5 shadow-sm ${className}`}>
      {(title || actions) && (
        <div className="mb-4 flex items-center justify-between gap-3">
          {title && <h2 className="text-base font-semibold text-body">{title}</h2>}
          {actions}
        </div>
      )}
      {children}
    </div>
  )
}

/** Page title + optional action buttons — the standard header for every page. */
export function PageHeader({ title, subtitle, actions }: { title: string; subtitle?: string; actions?: ReactNode }) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <div>
        <h1 className="text-xl font-bold text-body">{title}</h1>
        {subtitle && <p className="mt-0.5 text-sm text-muted">{subtitle}</p>}
      </div>
      {actions && <div className="flex flex-wrap gap-2">{actions}</div>}
    </div>
  )
}

const STAT_GRADIENTS: Record<string, string> = {
  blue: 'from-blue-500 to-blue-700',
  amber: 'from-amber-400 to-orange-600',
  green: 'from-emerald-400 to-green-600',
  red: 'from-orange-500 to-red-600',
  purple: 'from-violet-500 to-purple-700',
  navy: 'from-navy-600 to-navy-900',
}

/** Gradient KPI card with icon bubble — the dashboard's hero-number vocabulary,
 * reusable on any page that leads with a headline metric. */
export function StatCard({ label, value, icon, color = 'blue', footer }: { label: string; value: ReactNode; icon?: string; color?: keyof typeof STAT_GRADIENTS; footer?: ReactNode }) {
  return (
    <div className={`relative overflow-hidden rounded-2xl bg-gradient-to-br ${STAT_GRADIENTS[color]} p-5 text-white shadow-md`}>
      <div className="flex items-start justify-between">
        <div className="text-sm font-semibold text-white/90">{label}</div>
        {icon && <div className="flex h-11 w-11 items-center justify-center rounded-full bg-white/20 text-xl">{icon}</div>}
      </div>
      <div className="mt-1 text-3xl font-extrabold tracking-tight">{value}</div>
      {footer && <div className="mt-2 flex flex-wrap justify-end gap-1.5">{footer}</div>}
    </div>
  )
}

const FOCUSABLE = 'a[href],button:not([disabled]),textarea:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])'

export function Modal({ title, open, onClose, children }: { title: string; open: boolean; onClose: () => void; children: ReactNode }) {
  const dialogRef = useRef<HTMLDivElement>(null)
  const restoreRef = useRef<HTMLElement | null>(null)
  // Keep the latest onClose in a ref so the effect can depend on `open` ALONE.
  // Callers pass an inline onClose (new identity every render); if it were a
  // dependency, every keystroke would re-run this effect and steal focus back
  // to the first focusable element (the × button).
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose

  useEffect(() => {
    if (!open) return
    // Remember what had focus so we can return the user there on close.
    restoreRef.current = document.activeElement as HTMLElement | null
    const dialog = dialogRef.current
    const visibleFocusable = () =>
      Array.from(dialog?.querySelectorAll<HTMLElement>(FOCUSABLE) ?? []).filter((el) => el.offsetParent !== null || el === document.activeElement)
    // On open, focus the first field if there is one (else the first focusable),
    // so typing starts in the input rather than on the × button.
    const firstField = Array.from(dialog?.querySelectorAll<HTMLElement>('input, textarea, select') ?? []).find((el) => el.offsetParent !== null)
    ;(firstField ?? visibleFocusable()[0])?.focus()

    function onKeyDown(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onCloseRef.current()
        return
      }
      if (e.key !== 'Tab') return
      const els = visibleFocusable()
      if (els.length === 0) {
        e.preventDefault()
        return
      }
      const first = els[0]
      const last = els[els.length - 1]
      const active = document.activeElement
      // Wrap focus so Tab/Shift+Tab cycle stays trapped inside the dialog.
      if (e.shiftKey && (active === first || !dialog?.contains(active))) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && (active === last || !dialog?.contains(active))) {
        e.preventDefault()
        first.focus()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      restoreRef.current?.focus?.()
    }
  }, [open])

  if (!open) return null
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/50 p-4 pt-12" onClick={onClose}>
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        className="w-full max-w-2xl rounded-2xl border border-line bg-surface p-6 shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-body">{title}</h2>
          <button onClick={onClose} aria-label="Close" className="rounded-lg p-1 text-2xl leading-none text-muted hover:text-body">
            ×
          </button>
        </div>
        {children}
      </div>
    </div>
  )
}

// Each status maps to a hue; the badge renders a translucent chip that reads
// well on both light and dark surfaces (no flat pastel that vanishes in dark).
const STATUS_HUE: Record<string, string> = {
  pending: 'slate', assigned: 'blue', in_transit: 'amber', delivered: 'teal',
  completed: 'green', billed: 'purple', active: 'green', inactive: 'slate',
  terminated: 'red', available: 'green', in_use: 'blue', maintenance: 'amber',
  retired: 'slate', draft: 'slate', sent: 'blue', paid: 'green', void: 'red',
  cancelled: 'red',
}
const HUE_CLASS: Record<string, string> = {
  slate: 'bg-slate-500/15 text-slate-600 dark:text-slate-300',
  blue: 'bg-blue-500/15 text-blue-600 dark:text-blue-300',
  amber: 'bg-amber-500/15 text-amber-700 dark:text-amber-300',
  teal: 'bg-teal-500/15 text-teal-600 dark:text-teal-300',
  green: 'bg-green-500/15 text-green-700 dark:text-green-300',
  purple: 'bg-purple-500/15 text-purple-600 dark:text-purple-300',
  red: 'bg-red-500/15 text-red-600 dark:text-red-300',
}

export function Badge({ status }: { status: string }) {
  const hue = STATUS_HUE[status] ?? 'slate'
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold capitalize ${HUE_CLASS[hue]}`}>
      <span className={`h-1.5 w-1.5 rounded-full bg-current`} />
      {status.replace('_', ' ')}
    </span>
  )
}

/** A table header: a plain string (unsortable, as before) or `{ label, key }`
 * to make it click-to-sort. Pass `sort`/`onSort` when any header has a key. */
export type TableHeader = string | { label: string; key: string }
export interface SortState { key: string; dir: 'asc' | 'desc' }

export function Table({
  headers,
  children,
  sort,
  onSort,
}: {
  headers: TableHeader[]
  children: ReactNode
  sort?: SortState
  onSort?: (key: string) => void
}) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm text-body">
        <thead>
          <tr className="border-b border-line text-left">
            {headers.map((h, i) => {
              const label = typeof h === 'string' ? h : h.label
              const key = typeof h === 'string' ? null : h.key
              const active = key != null && sort?.key === key
              return (
                <th
                  key={`${label}-${i}`}
                  aria-sort={active ? (sort!.dir === 'asc' ? 'ascending' : 'descending') : undefined}
                  className="px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-muted"
                >
                  {key && onSort ? (
                    <button
                      onClick={() => onSort(key)}
                      className={`inline-flex items-center gap-1 uppercase tracking-wide hover:text-body ${active ? 'text-body' : ''}`}
                      title="Sort"
                    >
                      {label}
                      <span className={active ? '' : 'opacity-30'}>
                        {active ? (sort!.dir === 'asc' ? '▲' : '▼') : '↕'}
                      </span>
                    </button>
                  ) : (
                    label
                  )}
                </th>
              )
            })}
          </tr>
        </thead>
        <tbody className="divide-y divide-line">{children}</tbody>
      </table>
    </div>
  )
}

/** Standard sort-state toggler: clicking a new column sorts ascending;
 * clicking the same column again flips direction (no unsorted third state). */
export function toggleSort(prev: SortState | null, key: string): SortState {
  if (prev?.key === key) return { key, dir: prev.dir === 'asc' ? 'desc' : 'asc' }
  return { key, dir: 'asc' }
}

/** Compare helper for client-side sorts: numbers numerically, dates by time,
 * strings with natural/numeric-aware collation, null/undefined always last. */
export function compareValues(a: unknown, b: unknown): number {
  const aNil = a == null || a === ''
  const bNil = b == null || b === ''
  if (aNil && bNil) return 0
  if (aNil) return 1
  if (bNil) return -1
  if (typeof a === 'number' && typeof b === 'number') return a - b
  if (typeof a === 'boolean' && typeof b === 'boolean') return Number(a) - Number(b)
  return String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: 'base' })
}

/** Rendered in place of a list/detail body when its query failed — a failed
 * fetch must never masquerade as an empty state or an endless spinner. */
export function LoadError({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  return (
    <div className="py-8 text-center">
      <p className="text-sm font-medium text-red-600">Couldn't load data — {errorMessage(error)}</p>
      {onRetry && (
        <Button variant="secondary" className="mt-3" onClick={onRetry}>
          Try again
        </Button>
      )}
    </div>
  )
}

export function money(value: string | number | null | undefined): string {
  if (value == null) return '—'
  const n = typeof value === 'string' ? parseFloat(value) : value
  return n.toLocaleString('en-US', { style: 'currency', currency: 'USD' })
}

export function formatDate(value: string | null | undefined): string {
  if (!value) return '—'
  return new Date(value).toLocaleDateString()
}

export function formatDateTime(value: string | null | undefined): string {
  if (!value) return '—'
  return new Date(value).toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'short' })
}

/** "City, ST" from a full address ("123 Main St, Chicago, IL 60601" → "Chicago, IL").
 *  Handles missing zip, "City ST zip" without a comma, and bare "City, ST";
 *  anything unparseable falls back to the first address segment. */
export function cityState(address: string | null | undefined): string {
  if (!address) return '—'
  const parts = address.split(',').map((s) => s.trim()).filter(Boolean)
  // walk from the end looking for a "ST" or "ST 60601" segment; city precedes it
  for (let i = parts.length - 1; i > 0; i--) {
    const m = parts[i].match(/^([A-Za-z]{2})(?:\s+\d{5}(?:-\d{4})?)?$/)
    if (m) return `${parts[i - 1]}, ${m[1].toUpperCase()}`
  }
  // no comma before the state: "... , Chicago IL 60601"
  const last = parts[parts.length - 1].match(/^(.+?)\s+([A-Za-z]{2})\s+\d{5}(?:-\d{4})?$/)
  if (last) return `${last[1]}, ${last[2].toUpperCase()}`
  return parts[0]
}

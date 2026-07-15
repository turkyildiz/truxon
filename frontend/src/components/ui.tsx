import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode, SelectHTMLAttributes, TextareaHTMLAttributes } from 'react'

export function Button({ variant = 'primary', className = '', ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'primary' | 'secondary' | 'danger' }) {
  const styles = {
    primary: 'bg-navy-700 text-white hover:bg-navy-800',
    secondary: 'bg-white text-slate-700 border border-slate-300 hover:bg-slate-50',
    danger: 'bg-red-600 text-white hover:bg-red-700',
  }[variant]
  return (
    <button
      className={`rounded-lg px-4 py-2.5 text-sm font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed ${styles} ${className}`}
      {...props}
    />
  )
}

export function Input(props: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      {...props}
      className={`w-full rounded-lg border border-slate-300 px-3 py-2.5 text-sm focus:border-navy-600 focus:outline-none focus:ring-1 focus:ring-navy-600 bg-white ${props.className ?? ''}`}
    />
  )
}

export function Select(props: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select
      {...props}
      className={`w-full rounded-lg border border-slate-300 px-3 py-2.5 text-sm focus:border-navy-600 focus:outline-none bg-white ${props.className ?? ''}`}
    />
  )
}

export function Textarea(props: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      rows={3}
      {...props}
      className={`w-full rounded-lg border border-slate-300 px-3 py-2.5 text-sm focus:border-navy-600 focus:outline-none bg-white ${props.className ?? ''}`}
    />
  )
}

export function Field({ label, children, className = '' }: { label: string; children: ReactNode; className?: string }) {
  return (
    <label className={`block ${className}`}>
      <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-slate-500">{label}</span>
      {children}
    </label>
  )
}

export function Card({ title, children, actions, className = '' }: { title?: string; children: ReactNode; actions?: ReactNode; className?: string }) {
  return (
    <div className={`rounded-xl bg-white p-5 shadow-sm ${className}`}>
      {(title || actions) && (
        <div className="mb-4 flex items-center justify-between">
          {title && <h2 className="text-base font-semibold text-navy-800">{title}</h2>}
          {actions}
        </div>
      )}
      {children}
    </div>
  )
}

export function Modal({ title, open, onClose, children }: { title: string; open: boolean; onClose: () => void; children: ReactNode }) {
  if (!open) return null
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 pt-12" onClick={onClose}>
      <div className="w-full max-w-2xl rounded-xl bg-white p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-navy-800">{title}</h2>
          <button onClick={onClose} className="rounded p-1 text-2xl leading-none text-slate-400 hover:text-slate-600">
            ×
          </button>
        </div>
        {children}
      </div>
    </div>
  )
}

const STATUS_COLORS: Record<string, string> = {
  pending: 'bg-slate-200 text-slate-700',
  assigned: 'bg-blue-100 text-blue-800',
  in_transit: 'bg-amber-100 text-amber-800',
  delivered: 'bg-teal-100 text-teal-800',
  completed: 'bg-green-100 text-green-800',
  billed: 'bg-purple-100 text-purple-800',
  active: 'bg-green-100 text-green-800',
  inactive: 'bg-slate-200 text-slate-600',
  terminated: 'bg-red-100 text-red-800',
  available: 'bg-green-100 text-green-800',
  in_use: 'bg-blue-100 text-blue-800',
  maintenance: 'bg-amber-100 text-amber-800',
  retired: 'bg-slate-200 text-slate-600',
  draft: 'bg-slate-200 text-slate-700',
  sent: 'bg-blue-100 text-blue-800',
  paid: 'bg-green-100 text-green-800',
}

export function Badge({ status }: { status: string }) {
  return (
    <span className={`inline-block rounded-full px-2.5 py-1 text-xs font-semibold ${STATUS_COLORS[status] ?? 'bg-slate-200 text-slate-700'}`}>
      {status.replace('_', ' ')}
    </span>
  )
}

export function Table({ headers, children }: { headers: string[]; children: ReactNode }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-slate-200 text-left">
            {headers.map((h) => (
              <th key={h} className="px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-slate-500">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">{children}</tbody>
      </table>
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

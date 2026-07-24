/** Trux Sentinel feed — the "comes to you" panel. Shows the open insights the
 * scheduled scan found (money leaks, fuel-card misuse, overdue AR, late loads,
 * expiring compliance…) with an acknowledge action. Click a finding to open the
 * full evidence (the underlying transactions — truck, date/time, driver, card,
 * amount) plus a plain-English "why Forest flagged this" so the team can
 * investigate. Hidden entirely when there's nothing to show. */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { acknowledgeInsight, insightDetail, listInsights, snoozeInsight } from '../data'

const SEV: Record<string, { cls: string; icon: string }> = {
  critical: { cls: 'bg-red-500/15 text-red-600 dark:text-red-300', icon: '‼️' },
  warn: { cls: 'bg-amber-500/15 text-amber-700 dark:text-amber-300', icon: '⚠️' },
  info: { cls: 'bg-blue-500/15 text-blue-600 dark:text-blue-300', icon: 'ℹ️' },
}

const money = (v: unknown) =>
  typeof v === 'number' ? v.toLocaleString('en-US', { style: 'currency', currency: 'USD' }) : String(v ?? '')

function DetailModal({ id, onClose }: { id: number; onClose: () => void }) {
  const q = useQuery({ queryKey: ['insight', id], queryFn: () => insightDetail(id) })
  const d = q.data
  const rows = d?.records ?? []
  const cols = rows.length ? Object.keys(rows[0]) : []
  const s = SEV[d?.severity ?? 'info'] ?? SEV.info

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/50 p-4 sm:p-8" onClick={onClose}>
      <div className="w-full max-w-3xl rounded-2xl border border-line bg-surface p-5 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="mb-3 flex items-start justify-between gap-3">
          <div>
            <div className="flex items-center gap-2">
              <span className={`rounded px-1.5 py-0.5 text-xs font-semibold ${s.cls}`}>{s.icon} {d?.severity}</span>
              {d?.subject && <span className="text-xs font-medium text-muted">{d.subject}</span>}
            </div>
            <h3 className="mt-1 text-base font-semibold text-body">{d?.title ?? 'Loading…'}</h3>
            {d?.detail && <p className="text-sm text-muted">{d.detail}</p>}
          </div>
          <button onClick={onClose} aria-label="Dismiss" title="Dismiss" className="shrink-0 rounded-lg border border-line px-2 py-1 text-sm text-muted hover:text-body">✕</button>
        </div>

        {d?.why && (
          <div className="mb-4 rounded-lg border border-line bg-base/50 p-3">
            <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">Why Forest flagged this</div>
            <p className="text-sm text-body">{d.why}</p>
          </div>
        )}

        {q.isLoading && <div className="py-8 text-center text-sm text-muted">Loading evidence…</div>}
        {q.isError && <div className="py-8 text-center text-sm text-red-600">Couldn’t load the detail.</div>}

        {!q.isLoading && rows.length === 0 && (
          <div className="py-6 text-center text-sm text-muted">No line-item records for this finding.</div>
        )}

        {rows.length > 0 && (
          <div className="overflow-x-auto rounded-lg border border-line">
            <table className="w-full text-sm">
              <thead className="bg-base/60 text-left text-xs uppercase tracking-wide text-muted">
                <tr>{cols.map((c) => <th key={c} className="px-3 py-2 font-medium">{c}</th>)}</tr>
              </thead>
              <tbody>
                {rows.map((r, idx) => (
                  <tr key={idx} className="border-t border-line">
                    {cols.map((c) => (
                      <td key={c} className="whitespace-nowrap px-3 py-2 text-body">
                        {c === 'amount' || c === 'charge' || c === 'rate' ? money(r[c]) : String(r[c] ?? '')}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {d && (d.first_seen || d.last_seen) && (
          <div className="mt-3 text-xs text-muted">
            {d.first_seen && <>First seen {new Date(d.first_seen).toLocaleString()}</>}
            {d.last_seen && <> · last seen {new Date(d.last_seen).toLocaleString()}</>}
          </div>
        )}
      </div>
    </div>
  )
}

export default function SentinelFeed() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['insights'], queryFn: () => listInsights(false), refetchInterval: 60_000 })
  const ack = useMutation({
    mutationFn: (id: number) => acknowledgeInsight(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['insights'] }),
  })
  const snooze = useMutation({
    mutationFn: (id: number) => snoozeInsight(id, 7),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['insights'] }),
  })
  const [openId, setOpenId] = useState<number | null>(null)

  const items = q.data ?? []
  if (items.length === 0) return null
  const openCount = items.filter((i) => i.status === 'open').length

  return (
    <div className="rounded-2xl border border-line bg-surface p-4">
      <h2 className="mb-2 text-sm font-semibold text-body">
        🛡️ Forest is watching
        {openCount > 0 && <span className="font-normal text-muted"> · {openCount} need{openCount === 1 ? 's' : ''} attention</span>}
      </h2>
      <ul className="space-y-2">
        {items.slice(0, 8).map((i) => {
          const s = SEV[i.severity] ?? SEV.info
          return (
            <li
              key={i.id}
              onClick={() => setOpenId(i.id)}
              className="flex cursor-pointer items-start gap-3 rounded-lg border border-line p-2.5 hover:border-brand/50 hover:bg-base/40"
              title="Click for full evidence"
            >
              <span className={`mt-0.5 shrink-0 rounded px-1.5 py-0.5 text-xs font-semibold ${s.cls}`}>{s.icon} {i.severity}</span>
              <div className="min-w-0 flex-1">
                <div className="text-sm font-medium text-body">{i.title}</div>
                {i.detail && <div className="text-xs text-muted">{i.detail}</div>}
                <div className="mt-0.5 text-[11px] font-medium text-brand">Click to investigate →</div>
              </div>
              {i.status === 'open' ? (
                <span className="flex shrink-0 gap-1">
                  <button
                    onClick={(e) => { e.stopPropagation(); ack.mutate(i.id) }}
                    disabled={ack.isPending}
                    className="rounded-lg border border-line px-2 py-1 text-xs text-muted hover:text-body disabled:opacity-50"
                  >
                    Got it
                  </button>
                  <button
                    onClick={(e) => { e.stopPropagation(); snooze.mutate(i.id) }}
                    disabled={snooze.isPending}
                    title="Stays open, but the brief and pushes skip it for 7 days"
                    className="rounded-lg border border-line px-2 py-1 text-xs text-muted hover:text-body disabled:opacity-50"
                  >
                    😴 7d
                  </button>
                </span>
              ) : (
                <span className="shrink-0 text-xs text-muted">✓ acknowledged</span>
              )}
            </li>
          )
        })}
      </ul>
      {openId != null && <DetailModal id={openId} onClose={() => setOpenId(null)} />}
    </div>
  )
}

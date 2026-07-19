/** Trux Sentinel feed — the "comes to you" panel. Shows the open insights the
 * scheduled scan found (money leaks, overdue AR, late loads, expiring
 * compliance, overdue PM…) with an acknowledge action. Hidden entirely when
 * there's nothing to show, so it never clutters a clean board. */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { acknowledgeInsight, listInsights } from '../data'

const SEV: Record<string, { cls: string; icon: string }> = {
  critical: { cls: 'bg-red-500/15 text-red-600 dark:text-red-300', icon: '‼️' },
  warn: { cls: 'bg-amber-500/15 text-amber-700 dark:text-amber-300', icon: '⚠️' },
  info: { cls: 'bg-blue-500/15 text-blue-600 dark:text-blue-300', icon: 'ℹ️' },
}

export default function SentinelFeed() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['insights'], queryFn: () => listInsights(false), refetchInterval: 60_000 })
  const ack = useMutation({
    mutationFn: (id: number) => acknowledgeInsight(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['insights'] }),
  })

  const items = q.data ?? []
  if (items.length === 0) return null
  const openCount = items.filter((i) => i.status === 'open').length

  return (
    <div className="rounded-2xl border border-line bg-surface p-4">
      <h2 className="mb-2 text-sm font-semibold text-body">
        🛡️ Trux is watching
        {openCount > 0 && <span className="font-normal text-muted"> · {openCount} need{openCount === 1 ? 's' : ''} attention</span>}
      </h2>
      <ul className="space-y-2">
        {items.slice(0, 8).map((i) => {
          const s = SEV[i.severity] ?? SEV.info
          return (
            <li key={i.id} className="flex items-start gap-3 rounded-lg border border-line p-2.5">
              <span className={`mt-0.5 shrink-0 rounded px-1.5 py-0.5 text-xs font-semibold ${s.cls}`}>{s.icon} {i.severity}</span>
              <div className="min-w-0 flex-1">
                <div className="text-sm font-medium text-body">{i.title}</div>
                {i.detail && <div className="text-xs text-muted">{i.detail}</div>}
              </div>
              {i.status === 'open' ? (
                <button
                  onClick={() => ack.mutate(i.id)}
                  disabled={ack.isPending}
                  className="shrink-0 rounded-lg border border-line px-2 py-1 text-xs text-muted hover:text-body disabled:opacity-50"
                >
                  Got it
                </button>
              ) : (
                <span className="shrink-0 text-xs text-muted">✓ acknowledged</span>
              )}
            </li>
          )
        })}
      </ul>
    </div>
  )
}

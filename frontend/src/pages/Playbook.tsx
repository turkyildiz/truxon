import { useQuery } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { Card, LoadError, Select } from '../components/ui'
import { playbookCoverage, playbookMetrics, type PlaybookMetric } from '../data'

const STATUS_META: Record<string, { label: string; cls: string; dot: string }> = {
  live: { label: 'Live', cls: 'text-emerald-700 dark:text-emerald-300', dot: 'bg-emerald-500' },
  needs_data: { label: 'Needs data', cls: 'text-amber-700 dark:text-amber-300', dot: 'bg-amber-500' },
  external: { label: 'External feed', cls: 'text-sky-700 dark:text-sky-300', dot: 'bg-sky-500' },
  qualitative: { label: 'Judgment', cls: 'text-muted', dot: 'bg-slate-400' },
}

function StatusPill({ status }: { status: string }) {
  const m = STATUS_META[status] ?? STATUS_META.qualitative
  return (
    <span className={`inline-flex items-center gap-1.5 whitespace-nowrap text-xs font-medium ${m.cls}`}>
      <span className={`h-2 w-2 rounded-full ${m.dot}`} />
      {m.label}
    </span>
  )
}

export default function Playbook() {
  const covQ = useQuery({ queryKey: ['playbook-coverage'], queryFn: playbookCoverage, retry: false })
  const [status, setStatus] = useState('')
  const [owner, setOwner] = useState('')
  const [search, setSearch] = useState('')
  const listQ = useQuery({
    queryKey: ['playbook-metrics', status, owner, search],
    queryFn: () => playbookMetrics(status, owner, search),
    retry: false,
  })

  const cov = covQ.data
  const live = cov?.by_status?.live ?? 0
  const total = cov?.total ?? 1000
  const pct = total > 0 ? (live / total) * 100 : 0
  const owners = useMemo(
    () => Array.from(new Set((listQ.data ?? []).map((m) => m.owner_role).filter(Boolean))).sort(),
    [listQ.data],
  )

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <h1 className="text-xl font-bold text-body">Owner's Playbook</h1>
        <span className="rounded-full border border-line bg-surface-2 px-2.5 py-0.5 text-xs font-medium text-muted">
          the North Star — 1,000 metrics
        </span>
      </div>

      {covQ.isError ? (
        <LoadError error={covQ.error} onRetry={() => covQ.refetch()} />
      ) : (
        <Card title="Coverage">
          <div className="flex flex-wrap items-end gap-x-8 gap-y-3">
            <div>
              <div className="text-4xl font-bold text-body">
                {live}
                <span className="text-lg font-medium text-muted"> / {total} live</span>
              </div>
              <div className="mt-1 text-sm text-muted">{pct.toFixed(1)}% of the playbook is a measured number today.</div>
            </div>
            <div className="flex flex-wrap gap-x-5 gap-y-1">
              {(['live', 'needs_data', 'external', 'qualitative'] as const).map((s) => (
                <div key={s} className="flex items-center gap-1.5">
                  <span className={`h-2.5 w-2.5 rounded-full ${STATUS_META[s].dot}`} />
                  <span className="text-sm text-body">{cov?.by_status?.[s] ?? 0}</span>
                  <span className="text-xs text-muted">{STATUS_META[s].label}</span>
                </div>
              ))}
            </div>
          </div>
          <div className="mt-3 h-2.5 w-full overflow-hidden rounded-full bg-surface-2">
            <div className="h-full rounded-full bg-emerald-500" style={{ width: `${pct}%` }} />
          </div>

          {/* per-category coverage */}
          <div className="mt-5 grid grid-cols-1 gap-x-8 gap-y-2 sm:grid-cols-2">
            {(cov?.by_category ?? []).map((c) => {
              const cp = c.total > 0 ? (c.live / c.total) * 100 : 0
              return (
                <div key={c.category} className="flex items-center gap-3">
                  <span className="w-28 shrink-0 truncate text-sm text-body">{c.category}</span>
                  <div className="h-2 flex-1 overflow-hidden rounded-full bg-surface-2">
                    <div className="h-full rounded-full bg-emerald-500/80" style={{ width: `${cp}%` }} />
                  </div>
                  <span className="w-14 shrink-0 text-right text-xs text-muted">{c.live}/{c.total}</span>
                </div>
              )
            })}
          </div>
        </Card>
      )}

      <Card title="Metrics">
        <div className="mb-3 flex flex-wrap items-center gap-2">
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search metric name…"
            className="w-56 rounded-lg border border-line bg-surface px-3 py-1.5 text-sm"
          />
          <Select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All statuses</option>
            <option value="live">Live</option>
            <option value="needs_data">Needs data</option>
            <option value="external">External feed</option>
            <option value="qualitative">Judgment</option>
          </Select>
          <Select value={owner} onChange={(e) => setOwner(e.target.value)}>
            <option value="">All owners</option>
            {owners.map((o) => <option key={o} value={o}>{o}</option>)}
          </Select>
        </div>

        {listQ.isError ? (
          <LoadError error={listQ.error} onRetry={() => listQ.refetch()} />
        ) : listQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-line text-left">
                  {['#', 'Metric', 'Owner', 'Category', 'Status', 'Source'].map((h) => (
                    <th key={h} className="px-3 py-2 text-xs font-semibold uppercase tracking-wide text-muted">{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {(listQ.data ?? []).map((m: PlaybookMetric) => (
                  <tr key={m.number} className="hover:bg-surface-2">
                    <td className="px-3 py-2 text-muted">{m.number}</td>
                    <td className="px-3 py-2">
                      <span className="font-medium text-body">{m.name}</span>
                      {m.definition && <span className="block text-xs text-muted">{m.definition}</span>}
                    </td>
                    <td className="px-3 py-2 text-muted">{m.owner_role}</td>
                    <td className="px-3 py-2 text-muted">{m.category}</td>
                    <td className="px-3 py-2"><StatusPill status={m.status} /></td>
                    <td className="px-3 py-2 font-mono text-xs text-muted">{m.source || '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {(listQ.data?.length ?? 0) >= 300 && (
              <p className="mt-2 text-xs text-muted">Showing the first 300 — narrow with search or filters.</p>
            )}
          </div>
        )}
      </Card>
    </div>
  )
}

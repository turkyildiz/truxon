/**
 * Forest Shadow — the observe-only ledger of what Forest WOULD do with the
 * dispatch@ inbox. Nothing here executes anything; it's the evaluation feed the
 * owner reviews for a couple of months before promoting any action to real.
 */
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Card, formatDateTime, LoadError } from './ui'
import { listObservations, markObservationReviewed, type TruxObservation } from '../data'

const CLASS_META: Record<string, { label: string; emoji: string; cls: string }> = {
  rate_con: { label: 'Rate con', emoji: '📋', cls: 'bg-blue-500/15 text-blue-600 dark:text-blue-300' },
  pod: { label: 'POD', emoji: '📦', cls: 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-300' },
  bol: { label: 'BOL', emoji: '📃', cls: 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-300' },
  detention: { label: 'Detention', emoji: '⏱️', cls: 'bg-red-500/15 text-red-600 dark:text-red-300' },
  lumper: { label: 'Lumper', emoji: '💵', cls: 'bg-red-500/15 text-red-600 dark:text-red-300' },
  tonu: { label: 'TONU', emoji: '🚫', cls: 'bg-red-500/15 text-red-600 dark:text-red-300' },
  quote: { label: 'Quote', emoji: '💰', cls: 'bg-purple-500/15 text-purple-600 dark:text-purple-300' },
  load_offer: { label: 'Load offer', emoji: '🚚', cls: 'bg-amber-500/15 text-amber-600 dark:text-amber-300' },
  payment: { label: 'Payment', emoji: '🏦', cls: 'bg-teal-500/15 text-teal-600 dark:text-teal-300' },
  check_call: { label: 'Check call', emoji: '📞', cls: 'bg-sky-500/15 text-sky-600 dark:text-sky-300' },
  claim: { label: 'Claim', emoji: '⚠️', cls: 'bg-orange-500/15 text-orange-600 dark:text-orange-300' },
  other: { label: 'Other', emoji: '✉️', cls: 'bg-slate-500/15 text-slate-600 dark:text-slate-300' },
}
const ACTION_LABEL: Record<string, string> = {
  create_load: 'would create a load',
  file_document: 'would file the document',
  flag_accessorial: 'would flag an accessorial charge',
  enrich_customer: 'would update a customer record',
  draft_reply: 'would draft a reply',
  none: 'no action needed',
}
const CONF_DOT: Record<string, string> = { high: 'bg-emerald-500', medium: 'bg-amber-500', low: 'bg-red-500' }

export default function TruxShadow() {
  const [classFilter, setClassFilter] = useState('')
  const [showReviewed, setShowReviewed] = useState(false)
  const qc = useQueryClient()
  const obsQ = useQuery({
    queryKey: ['trux-obs', classFilter, showReviewed],
    queryFn: () => listObservations({ classification: classFilter || undefined, unreviewedOnly: !showReviewed, limit: 150 }),
    refetchInterval: 60_000,
  })
  const obs = obsQ.data ?? []

  async function review(o: TruxObservation) {
    try {
      await markObservationReviewed(o.id, !o.reviewed)
      qc.invalidateQueries({ queryKey: ['trux-obs'] })
    } catch { /* surfaced by refetch */ }
  }

  const counts: Record<string, number> = {}
  for (const o of obs) counts[o.classification] = (counts[o.classification] ?? 0) + 1

  return (
    <div className="mx-auto w-full max-w-3xl space-y-4 overflow-y-auto pb-6">
      <Card>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h2 className="font-semibold text-body">👁️ Shadow mode — observing dispatch@aidalogistics.com</h2>
            <p className="mt-1 text-sm text-muted">
              Forest reads the inbox every 20 minutes and records what it <em>would</em> do. It executes nothing and sends
              nothing — this feed is how you judge it before any action is ever promoted to real.
            </p>
          </div>
        </div>
      </Card>

      <div className="flex flex-wrap items-center gap-2">
        <button
          onClick={() => setClassFilter('')}
          className={`rounded-full border px-3 py-1.5 text-sm font-medium ${classFilter === '' ? 'border-brand bg-brand text-white' : 'border-line text-muted hover:bg-surface-2'}`}
        >
          All
        </button>
        {Object.entries(CLASS_META).map(([k, m]) => (
          <button
            key={k}
            onClick={() => setClassFilter(classFilter === k ? '' : k)}
            className={`rounded-full border px-3 py-1.5 text-sm font-medium ${classFilter === k ? 'border-brand bg-brand text-white' : 'border-line text-muted hover:bg-surface-2'}`}
          >
            {m.emoji} {m.label}
            {counts[k] ? <span className="ml-1 opacity-70">({counts[k]})</span> : null}
          </button>
        ))}
        <span className="mx-1 h-5 w-px self-center bg-line" />
        <label className="flex cursor-pointer items-center gap-1.5 text-sm text-muted">
          <input type="checkbox" checked={showReviewed} onChange={(e) => setShowReviewed(e.target.checked)} className="h-4 w-4" />
          include reviewed
        </label>
      </div>

      {obsQ.isError ? (
        <LoadError error={obsQ.error} onRetry={() => obsQ.refetch()} />
      ) : obs.length === 0 ? (
        <Card>
          <p className="py-6 text-center text-muted">
            {obsQ.isLoading ? 'Loading…' : showReviewed ? 'No observations yet.' : 'All caught up — nothing unreviewed. 🎉'}
          </p>
        </Card>
      ) : (
        obs.map((o) => {
          const m = CLASS_META[o.classification] ?? CLASS_META.other
          return (
            <Card key={o.id} className={o.reviewed ? 'opacity-60' : ''}>
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className={`inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold ${m.cls}`}>
                      {m.emoji} {m.label}
                    </span>
                    <span className="inline-flex items-center gap-1.5 text-xs text-muted" title={`confidence: ${o.confidence}`}>
                      <span className={`h-2 w-2 rounded-full ${CONF_DOT[o.confidence] ?? 'bg-slate-400'}`} />
                      {o.confidence}
                    </span>
                    <span className="text-xs text-muted">{formatDateTime(o.received_at)}</span>
                  </div>
                  <p className="mt-2 text-sm text-body">
                    <span className="font-medium">{o.sender_name || o.sender_email}</span>
                    <span className="text-muted"> — {o.subject || '(no subject)'}</span>
                  </p>
                  <p className="mt-1 text-sm text-muted">{o.summary}</p>
                  <p className="mt-2 rounded-lg bg-surface-2 px-3 py-2 text-sm">
                    <span className="font-semibold text-brand">Forest {ACTION_LABEL[o.would_action] ?? o.would_action}:</span>{' '}
                    <span className="text-body">{o.would_detail || '—'}</span>
                  </p>
                  {(o.matched_customer_id || o.matched_load_id || o.extracted?.amount) && (
                    <p className="mt-1.5 text-xs text-muted">
                      {o.matched_customer_id && <Link to="/customers" className="text-blue-600 hover:underline dark:text-blue-400">matched customer #{o.matched_customer_id}</Link>}
                      {o.matched_load_id && <Link to={`/loads/${o.matched_load_id}`} className="ml-2 text-blue-600 hover:underline dark:text-blue-400">load #{o.matched_load_id}</Link>}
                      {o.extracted?.amount != null && <span className="ml-2">${Number(o.extracted.amount).toLocaleString()}</span>}
                      {o.extracted?.ref && <span className="ml-2">ref {o.extracted.ref}</span>}
                    </p>
                  )}
                </div>
                <button
                  onClick={() => review(o)}
                  className="shrink-0 rounded-lg border border-line px-3 py-1.5 text-sm text-muted transition-colors hover:bg-surface-2 hover:text-body"
                  title={o.reviewed ? 'Mark as not reviewed' : 'Mark as reviewed'}
                >
                  {o.reviewed ? '↩ Unreview' : '✓ Reviewed'}
                </button>
              </div>
            </Card>
          )
        })
      )}
    </div>
  )
}

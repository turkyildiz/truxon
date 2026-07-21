import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button, Card, LoadError, Select, formatDateTime } from '../components/ui'
import { listObservations, markObservationReviewed, shadowSummary, type TruxObservation } from '../data'

const CLASS_META: Record<string, { label: string; icon: string }> = {
  rate_con: { label: 'Rate con', icon: '📋' },
  load_offer: { label: 'Load offer', icon: '📦' },
  pod: { label: 'POD', icon: '📄' },
  bol: { label: 'BOL', icon: '📄' },
  detention: { label: 'Detention', icon: '⏱️' },
  lumper: { label: 'Lumper', icon: '🏗️' },
  tonu: { label: 'TONU', icon: '🚫' },
  quote: { label: 'Quote', icon: '💬' },
  payment: { label: 'Payment', icon: '💵' },
  check_call: { label: 'Check call', icon: '📞' },
  claim: { label: 'Claim', icon: '⚠️' },
  other: { label: 'Other', icon: '✉️' },
}

const ACTION_LABEL: Record<string, string> = {
  create_load: 'would create a load',
  file_document: 'would file the document',
  flag_accessorial: 'would flag an accessorial',
  enrich_customer: 'would enrich the customer',
  draft_reply: 'would draft a reply',
  none: 'no action',
}

const CONFIDENCE_CLS: Record<string, string> = {
  high: 'text-emerald-700 dark:text-emerald-300',
  medium: 'text-amber-700 dark:text-amber-300',
  low: 'text-muted',
}

function ObservationRow({ o }: { o: TruxObservation }) {
  const qc = useQueryClient()
  const [note, setNote] = useState('')
  const [expanded, setExpanded] = useState(false)
  const review = useMutation({
    mutationFn: () => markObservationReviewed(o.id, true, note),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['shadow-observations'] })
      qc.invalidateQueries({ queryKey: ['shadow-summary'] })
    },
  })
  const cm = CLASS_META[o.classification] ?? CLASS_META.other

  return (
    <div className={`rounded-xl border border-line p-3 ${o.reviewed ? 'opacity-60' : 'bg-surface'}`}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm">{cm.icon}</span>
            <span className="text-xs font-semibold uppercase tracking-wide text-muted">{cm.label}</span>
            <span className={`text-xs font-medium ${CONFIDENCE_CLS[o.confidence]}`}>{o.confidence} confidence</span>
            <span className="text-xs text-muted">{formatDateTime(o.received_at ?? o.created_at)}</span>
          </div>
          <div className="mt-1 truncate text-sm font-medium text-body">{o.subject || '(no subject)'}</div>
          <div className="truncate text-xs text-muted">
            {o.sender_name ? `${o.sender_name} · ` : ''}{o.sender_email}
          </div>
        </div>
        {!o.reviewed && (
          <Button variant="secondary" onClick={() => review.mutate()} disabled={review.isPending}>
            {review.isPending ? 'Saving…' : '✓ Reviewed'}
          </Button>
        )}
      </div>

      {o.summary && <p className="mt-2 text-sm text-body">{o.summary}</p>}

      <div className="mt-2 rounded-lg bg-surface-2 px-3 py-2 text-sm">
        <span className="font-medium text-body">Forest {ACTION_LABEL[o.would_action] ?? o.would_action}</span>
        {o.would_detail && <span className="text-muted"> — {o.would_detail}</span>}
      </div>

      <div className="mt-2 flex flex-wrap items-center gap-3 text-xs">
        {o.matched_load_id && (
          <Link to={`/loads/${o.matched_load_id}`} className="font-medium text-brand hover:underline">
            → Load #{o.matched_load_id}
          </Link>
        )}
        {o.matched_customer_id && (
          <Link to="/customers" className="font-medium text-brand hover:underline">
            → Customer #{o.matched_customer_id}
          </Link>
        )}
        {o.extracted && (
          <button className="text-muted hover:underline" onClick={() => setExpanded((v) => !v)}>
            {expanded ? 'Hide extracted data' : 'Show extracted data'}
          </button>
        )}
        {o.reviewed && o.review_note && <span className="text-muted">Note: {o.review_note}</span>}
      </div>
      {expanded && o.extracted && (
        <pre className="mt-2 overflow-x-auto rounded-lg bg-surface-2 p-3 text-xs text-muted">
          {JSON.stringify(o.extracted, null, 2)}
        </pre>
      )}
      {!o.reviewed && (
        <input
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Optional review note (was Forest right?)"
          className="mt-2 w-full rounded-lg border border-line bg-surface px-3 py-1.5 text-xs"
        />
      )}
    </div>
  )
}

export default function Shadow() {
  const [classification, setClassification] = useState('')
  const [unreviewedOnly, setUnreviewedOnly] = useState(true)
  const sumQ = useQuery({ queryKey: ['shadow-summary'], queryFn: shadowSummary, retry: false })
  const listQ = useQuery({
    queryKey: ['shadow-observations', classification, unreviewedOnly],
    queryFn: () => listObservations({ classification: classification || undefined, unreviewedOnly }),
    retry: false,
  })
  const s = sumQ.data

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <h1 className="text-xl font-bold text-body">Forest Shadow</h1>
        <span className="rounded-full border border-line bg-surface-2 px-2.5 py-0.5 text-xs font-medium text-muted">
          dispatch@ · observe-only — Forest logs what it would do, executes nothing
        </span>
      </div>

      {sumQ.isError ? (
        <LoadError error={sumQ.error} onRetry={() => sumQ.refetch()} />
      ) : (
        <Card>
          <div className="flex flex-wrap items-end gap-x-8 gap-y-3">
            <div>
              <div className="text-4xl font-bold text-body">
                {s?.unreviewed ?? 0}
                <span className="text-lg font-medium text-muted"> awaiting review</span>
              </div>
              <div className="mt-1 text-sm text-muted">
                {s?.total ?? 0} observations total · {s?.last_7d ?? 0} in the last 7 days
                {s?.last_email_at ? ` · newest email ${formatDateTime(s.last_email_at)}` : ''}
              </div>
            </div>
            <div className="flex flex-wrap gap-x-4 gap-y-1">
              {Object.entries(s?.by_classification ?? {})
                .sort((a, b) => b[1] - a[1])
                .map(([k, n]) => (
                  <button
                    key={k}
                    onClick={() => setClassification(classification === k ? '' : k)}
                    className={`flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium ${
                      classification === k ? 'border-brand text-brand' : 'border-line text-muted hover:text-body'
                    }`}
                  >
                    <span>{CLASS_META[k]?.icon ?? '✉️'}</span>
                    {CLASS_META[k]?.label ?? k}
                    <span className="text-body">{n}</span>
                  </button>
                ))}
            </div>
          </div>
        </Card>
      )}

      <Card title="Observation feed">
        <div className="mb-3 flex flex-wrap items-center gap-2">
          <Select value={classification} onChange={(e) => setClassification(e.target.value)}>
            <option value="">All types</option>
            {Object.entries(CLASS_META).map(([k, m]) => (
              <option key={k} value={k}>{m.label}</option>
            ))}
          </Select>
          <label className="flex items-center gap-2 text-sm text-body">
            <input
              type="checkbox"
              checked={unreviewedOnly}
              onChange={(e) => setUnreviewedOnly(e.target.checked)}
            />
            Unreviewed only
          </label>
        </div>
        {listQ.isError ? (
          <LoadError error={listQ.error} onRetry={() => listQ.refetch()} />
        ) : listQ.isLoading ? (
          <p className="py-8 text-center text-muted">Loading…</p>
        ) : (listQ.data?.length ?? 0) === 0 ? (
          <p className="py-8 text-center text-muted">
            {unreviewedOnly ? 'All caught up — nothing awaiting review.' : 'No observations yet.'}
          </p>
        ) : (
          <div className="space-y-3">
            {(listQ.data ?? []).map((o) => <ObservationRow key={o.id} o={o} />)}
          </div>
        )}
      </Card>
    </div>
  )
}

import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'

/** R9 #127/#133: the public load-status page a customer opens from a share
 * link. No login, no SPA chrome — one load's status via the load-share edge
 * function (token-bounded), plus a thumbs up/down once it's delivered. */

interface ShareView {
  load_number: string
  carrier: string
  customer: string
  status: string
  pickup: { address: string; time: string | null }
  delivery: { address: string; time: string | null }
  near: string | null
  pod_on_file: boolean
  delivered: boolean
  feedback: string | null
}

const STATUS_LABEL: Record<string, string> = {
  pending: 'Booked',
  assigned: 'Driver assigned',
  in_transit: 'Rolling',
  delivered: 'Delivered',
  completed: 'Delivered',
  billed: 'Delivered',
}

const fnUrl = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/load-share`

export default function Share() {
  const { token = '' } = useParams()
  const [view, setView] = useState<ShareView | null>(null)
  const [err, setErr] = useState('')
  const [comment, setComment] = useState('')
  const [sending, setSending] = useState(false)

  useEffect(() => {
    fetch(`${fnUrl}?t=${encodeURIComponent(token)}`)
      .then(async (r) => {
        const body = await r.json()
        if (!r.ok) throw new Error(body.error ?? 'Unavailable')
        setView(body as ShareView)
      })
      .catch((e) => setErr(e instanceof Error ? e.message : 'Unavailable'))
  }, [token])

  async function sendFeedback(rating: 'up' | 'down') {
    setSending(true)
    try {
      const r = await fetch(fnUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ t: token, rating, comment }),
      })
      const body = await r.json()
      if (!r.ok && r.status !== 409) throw new Error(body.error ?? 'Could not record feedback')
      setView((v) => (v ? { ...v, feedback: rating } : v))
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not record feedback')
    } finally {
      setSending(false)
    }
  }

  const when = (t: string | null) =>
    t ? new Date(t).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : null

  return (
    <div className="mx-auto flex min-h-screen max-w-lg flex-col justify-center gap-4 p-6">
      {err && !view && (
        <div className="rounded-xl border border-gray-200 bg-white p-6 text-center text-gray-600 shadow dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300">
          {err}
        </div>
      )}
      {!err && !view && <p className="text-center text-gray-400">Loading…</p>}
      {view && (
        <div className="rounded-xl border border-gray-200 bg-white p-6 shadow dark:border-gray-700 dark:bg-gray-800">
          <p className="text-xs font-semibold uppercase tracking-wide text-gray-400">{view.carrier} · Load {view.load_number}</p>
          <p className="mt-1 text-2xl font-bold text-gray-900 dark:text-gray-50">
            {STATUS_LABEL[view.status] ?? view.status}
            {view.near && <span className="block text-sm font-normal text-gray-500 dark:text-gray-400">near {view.near}</span>}
          </p>
          <div className="mt-4 space-y-3 text-sm">
            <div>
              <p className="font-semibold text-gray-700 dark:text-gray-200">Pickup</p>
              <p className="text-gray-500 dark:text-gray-400">{view.pickup.address || '—'}{when(view.pickup.time) ? ` · ${when(view.pickup.time)}` : ''}</p>
            </div>
            <div>
              <p className="font-semibold text-gray-700 dark:text-gray-200">Delivery</p>
              <p className="text-gray-500 dark:text-gray-400">{view.delivery.address || '—'}{when(view.delivery.time) ? ` · ${when(view.delivery.time)}` : ''}</p>
            </div>
            {view.delivered && view.pod_on_file && (
              <p className="text-emerald-600 dark:text-emerald-400">✓ Proof of delivery is on file — ask us for a copy any time.</p>
            )}
          </div>
          {view.delivered && (
            <div className="mt-5 border-t border-gray-200 pt-4 dark:border-gray-700">
              {view.feedback ? (
                <p className="text-sm text-gray-500 dark:text-gray-400">Thanks for the feedback — noted {view.feedback === 'up' ? '👍' : '👎'}.</p>
              ) : (
                <>
                  <p className="text-sm font-semibold text-gray-700 dark:text-gray-200">How did we do on this load?</p>
                  <textarea
                    className="mt-2 w-full rounded border border-gray-300 p-2 text-sm dark:border-gray-600 dark:bg-gray-900 dark:text-gray-100"
                    rows={2}
                    placeholder="Anything we should know? (optional)"
                    value={comment}
                    onChange={(e) => setComment(e.target.value)}
                  />
                  <div className="mt-2 flex gap-3">
                    <button type="button" disabled={sending} onClick={() => void sendFeedback('up')}
                      className="rounded-lg bg-emerald-600 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-500 disabled:opacity-50">
                      👍 Good
                    </button>
                    <button type="button" disabled={sending} onClick={() => void sendFeedback('down')}
                      className="rounded-lg bg-rose-600 px-4 py-2 text-sm font-semibold text-white hover:bg-rose-500 disabled:opacity-50">
                      👎 Not good
                    </button>
                  </div>
                </>
              )}
            </div>
          )}
        </div>
      )}
      <p className="text-center text-xs text-gray-400">This page shows one load only, live from the carrier&rsquo;s system.</p>
    </div>
  )
}

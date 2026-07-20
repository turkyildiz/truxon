/** FMCSA safety profile — the carrier's rating, out-of-service rates vs the
 *  national average, crashes, and BASIC scores. Auto-fed weekly by fmcsa-watch;
 *  an admin can pull a fresh one on demand. */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../auth'
import { carrierSafety, runFmcsaCheck } from '../data'
import { errorMessage } from '../supabase'
import { Button, Card, formatDate } from './ui'

const BASIC_LABEL: Record<string, string> = {
  unsafe_driving: 'Unsafe Driving', hos: 'Hours of Service', driver_fitness: 'Driver Fitness',
  controlled_substances: 'Controlled Subst.', vehicle_maint: 'Vehicle Maint.', hazmat: 'HazMat', crash: 'Crash Indicator',
}

function RatingBadge({ rating, label }: { rating: string; label: string | null }) {
  const r = (rating || '').toUpperCase()
  const cls = r === 'S' ? 'bg-green-500/15 text-green-700 dark:text-green-300'
    : r === 'C' ? 'bg-amber-500/15 text-amber-700 dark:text-amber-300'
    : r === 'U' ? 'bg-red-500/15 text-red-700 dark:text-red-300'
    : 'bg-slate-400/15 text-muted'
  return <span className={`rounded-full px-2.5 py-0.5 text-sm font-semibold ${cls}`}>{label ?? 'Not Rated'}</span>
}

function OosRow({ label, rate, natl }: { label: string; rate: number | null; natl: number | null }) {
  const over = rate != null && natl != null && rate > natl
  return (
    <div className="flex items-center justify-between text-sm">
      <span className="text-muted">{label} out-of-service</span>
      <span className={over ? 'font-semibold text-red-600 dark:text-red-400' : 'font-medium text-body'}>
        {rate == null ? '—' : `${rate.toFixed(1)}%`}
        {natl != null && <span className="ml-1 text-xs font-normal text-muted">(natl {natl.toFixed(1)}%)</span>}
      </span>
    </div>
  )
}

export default function CarrierSafetyCard() {
  const qc = useQueryClient()
  const { user } = useAuth()
  const isAdmin = user?.role === 'admin'
  const [err, setErr] = useState('')
  const q = useQuery({ queryKey: ['carrier-safety'], queryFn: carrierSafety })
  const check = useMutation({
    mutationFn: runFmcsaCheck,
    onSuccess: (r) => {
      setErr('')
      if ((r as { skipped?: string }).skipped) setErr(`Skipped: ${(r as { skipped?: string }).skipped}`)
      qc.invalidateQueries({ queryKey: ['carrier-safety'] })
    },
    onError: (e) => setErr(errorMessage(e)),
  })

  const data = q.data
  const snap = data?.snapshot ?? null
  const basics = (data?.basics ?? []).filter((b) => BASIC_LABEL[b.basic])

  return (
    <Card
      title="FMCSA Safety"
      actions={isAdmin && (
        <Button variant="secondary" onClick={() => check.mutate()} disabled={check.isPending}>
          {check.isPending ? 'Checking…' : 'Check now'}
        </Button>
      )}
    >
      {err && <p className="mb-3 text-sm text-amber-600">{err}</p>}
      {q.isLoading ? (
        <p className="py-6 text-center text-muted">Loading…</p>
      ) : !data?.usdot ? (
        <p className="py-6 text-center text-sm text-muted">
          No USDOT number set. Add it in <Link to="/settings" className="text-brand hover:underline">Settings</Link> to turn on FMCSA monitoring.
        </p>
      ) : !snap ? (
        <p className="py-6 text-center text-sm text-muted">
          No FMCSA data pulled yet.{isAdmin ? ' Press “Check now”.' : ''}
        </p>
      ) : (
        <div className="space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex items-center gap-3">
              <RatingBadge rating={snap.safety_rating} label={data.rating_label} />
              {snap.allowed_to_operate === 'N' && (
                <span className="rounded-full bg-red-500/15 px-2.5 py-0.5 text-sm font-semibold text-red-700 dark:text-red-300">NOT authorized to operate</span>
              )}
            </div>
            <span className="text-xs text-muted">USDOT {snap.dot_number} · as of {formatDate(snap.snapshot_date)}</span>
          </div>

          <div className="grid grid-cols-1 gap-x-8 gap-y-1.5 sm:grid-cols-2">
            <OosRow label="Driver" rate={snap.driver_oos_rate} natl={snap.driver_oos_natl} />
            <OosRow label="Vehicle" rate={snap.vehicle_oos_rate} natl={snap.vehicle_oos_natl} />
            <div className="flex items-center justify-between text-sm">
              <span className="text-muted">Crashes (24 mo)</span>
              <span className="font-medium text-body">{snap.crash_total ?? '—'}{snap.fatal_crash ? ` · ${snap.fatal_crash} fatal` : ''}</span>
            </div>
            <div className="flex items-center justify-between text-sm">
              <span className="text-muted">Power units · ISS</span>
              <span className="font-medium text-body">{snap.total_power_units ?? '—'}{snap.iss_score != null ? ` · ISS ${snap.iss_score}` : ''}</span>
            </div>
          </div>

          {basics.length > 0 && (
            <div>
              <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">CSA BASIC scores</div>
              <ul className="divide-y divide-line text-sm">
                {basics.map((b) => (
                  <li key={b.basic} className="flex items-center justify-between py-1.5">
                    <span className={b.alert ? 'font-semibold text-red-600 dark:text-red-400' : 'text-body'}>
                      {b.alert && '⚠ '}{BASIC_LABEL[b.basic]}
                    </span>
                    <span className={b.alert ? 'font-semibold text-red-600 dark:text-red-400' : 'text-muted'}>
                      {b.percentile == null ? 'Not public' : `${b.percentile.toFixed(0)}th pct`}
                      {b.alert && ' · over threshold'}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </Card>
  )
}

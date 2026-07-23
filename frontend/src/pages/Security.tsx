import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../auth'
import { Badge, Button, Card, Field, LoadError, Modal, PageHeader, formatDateTime } from '../components/ui'
import MfaCard from '../components/MfaCard'
import {
  blessSecurityBaseline,
  machineHeartbeats,
  securityConsole, securityScorecard, setLockdown, type SecurityConsole,
} from '../data'
import { errorMessage } from '../supabase'

function Stat({ label, value, ok, warn }: { label: string; value: string; ok?: boolean; warn?: boolean }) {
  const tone = warn ? 'text-danger' : ok ? 'text-success' : 'text-fg'
  return (
    <div className="rounded-lg border border-line bg-surface px-4 py-3">
      <div className="text-xs uppercase tracking-wide text-muted">{label}</div>
      <div className={`mt-1 text-lg font-semibold ${tone}`}>{value}</div>
    </div>
  )
}

const EVENT_META: Record<string, { label: string; icon: string }> = {
  admin_granted: { label: 'Admin granted', icon: '🛡️' },
  role_change: { label: 'Role change', icon: '🔀' },
  account_deactivated: { label: 'Account deactivated', icon: '🚫' },
  invoice_void: { label: 'Invoice voided', icon: '🧾' },
  destructive_ddl_blocked: { label: 'Destructive op BLOCKED', icon: '🧨' },
  destructive_dml_blocked: { label: 'Mass delete BLOCKED', icon: '🧨' },
  bulk_dml_detected: { label: 'Unusually large update', icon: '⚠️' },
  honeytoken_replayed: { label: 'Honeytoken replayed', icon: '🍯' },
  lockdown_engaged: { label: 'Lockdown engaged', icon: '🔒' },
  lockdown_lifted: { label: 'Lockdown lifted', icon: '🔓' },
  security_baseline_blessed: { label: 'Baseline re-blessed', icon: '✅' },
}

/** Every machine reporting in: Lynx GPU box (with VRAM/temp from its own
 * heartbeat detail), offsite NAS replication, nightly backups (R9-A #10). */
function MachinesCard() {
  const q = useQuery({ queryKey: ['machine-heartbeats'], queryFn: machineHeartbeats, refetchInterval: 60_000, retry: false })
  const rows = q.data ?? []
  if (q.isError || rows.length === 0) return null
  const STALE_H: Record<string, number> = { lynx: 1, backup: 26, offsite: 26 }
  return (
    <Card title="🖥️ Machines">
      <table className="w-full text-sm">
        <tbody>
          {rows.map((h) => {
            const ageH = (Date.now() - new Date(h.last_seen).getTime()) / 3600_000
            const stale = ageH > (STALE_H[h.source] ?? 26)
            // a fresh heartbeat can still carry bad news (drill-proven:
            // 'ollama=inactive' arrived 24s after the service died)
            const sick = /inactive|failed|error/i.test(h.detail ?? '')
            const bad = stale || sick
            return (
              <tr key={h.source} className="border-t border-line">
                <td className="px-2 py-1.5 font-medium">{h.source}</td>
                <td className={`px-2 py-1.5 ${bad ? 'font-semibold text-rose-600 dark:text-rose-400' : 'text-green-700 dark:text-green-300'}`}>
                  {stale ? `⚠ silent ${Math.round(ageH)}h` : sick ? `⚠ ${formatDateTime(h.last_seen)}` : `✓ ${formatDateTime(h.last_seen)}`}
                </td>
                <td className={`px-2 py-1.5 ${sick ? 'font-semibold text-rose-600 dark:text-rose-400' : 'text-muted'}`}>{h.detail ?? ''}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </Card>
  )
}

export default function Security() {
  const { user } = useAuth()
  const qc = useQueryClient()
  const isAdmin = user?.role === 'admin'
  const [lockOpen, setLockOpen] = useState(false)
  const [reason, setReason] = useState('')
  const [err, setErr] = useState('')

  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['security-console'],
    queryFn: securityConsole,
    refetchInterval: 60_000,
  })

  const lock = useMutation({
    mutationFn: (on: boolean) => setLockdown(on, reason || (on ? 'manual lockdown' : 'lifted')),
    onSuccess: () => { setLockOpen(false); setReason(''); setErr(''); qc.invalidateQueries({ queryKey: ['security-console'] }) },
    onError: (e) => setErr(errorMessage(e)),
  })
  const bless = useMutation({
    mutationFn: blessSecurityBaseline,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['security-console'] }),
    onError: (e) => setErr(errorMessage(e)),
  })

  if (isLoading) return <div className="p-6 text-muted">Loading security posture…</div>
  if (error) return <div className="p-6"><LoadError error={error} onRetry={refetch} /></div>
  const c = data as SecurityConsole

  const chainOk = c.audit_chain?.intact
  const posture: [string, string, boolean, boolean][] = [
    ['Ransomware guard', c.guard_armed ? 'Armed' : 'OFF', c.guard_armed, !c.guard_armed],
    ['Audit chain', chainOk ? `Intact (${c.audit_chain.checked})` : `BROKEN @${c.audit_chain.broken_at_id}`, !!chainOk, !chainOk],
    ['Lockdown', c.lockdown ? 'ENGAGED' : 'Normal', false, c.lockdown],
    ['Honeytokens', String(c.honeytokens), c.honeytokens > 0, false],
    ['Canary account', c.canary_present ? 'Live' : 'MISSING', c.canary_present, !c.canary_present],
    ['Drift baseline', `${c.baseline_items} items`, c.baseline_items > 0, false],
  ]

  return (
    <div className="space-y-6 p-4 lg:p-6">
      <MachinesCard />
      <PageHeader
        title="Security"
        subtitle="Intrusion posture, the tamper-evident audit log, and break-glass controls."
        actions={
          isAdmin && (
            <Button variant={c.lockdown ? 'secondary' : 'danger'} onClick={() => setLockOpen(true)}>
              {c.lockdown ? 'Lift lockdown' : '🔒 Engage lockdown'}
            </Button>
          )
        }
      />

      {c.critical_open > 0 && (
        <div className="rounded-lg border border-danger/40 bg-danger/10 px-4 py-3 text-sm">
          <span className="font-semibold text-danger">{c.critical_open} open critical security {c.critical_open === 1 ? 'alert' : 'alerts'}.</span>{' '}
          Review them on <Link className="underline" to="/forest">Forest</Link>.
        </div>
      )}

      <Card title="Posture">
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          {posture.map(([l, v, ok, warn]) => <Stat key={l} label={l} value={v} ok={ok} warn={warn} />)}
        </div>
        {isAdmin && (
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <Button variant="secondary" onClick={() => bless.mutate()} disabled={bless.isPending}>
              {bless.isPending ? 'Re-blessing…' : 'Re-bless drift baseline'}
            </Button>
            <span className="text-xs text-muted">
              Accept the current permissions as the new known-good (audited). Do this after an intentional change.
            </span>
          </div>
        )}
        {err && <p className="mt-3 text-sm text-danger">{err}</p>}
      </Card>

      <MfaCard />

      <TechMetricsCard />

      {c.open_findings.length > 0 && (
        <Card title={`Open security alerts (${c.open_findings.length})`}>
          <ul className="divide-y divide-line">
            {c.open_findings.map((f) => (
              <li key={f.id} className="flex items-center justify-between gap-3 py-2">
                <Link to="/forest" className="text-sm hover:underline">{f.title}</Link>
                <div className="flex items-center gap-2 whitespace-nowrap">
                  <Badge status={f.severity} />
                  <span className="text-xs text-muted">{formatDateTime(f.last_seen)}</span>
                </div>
              </li>
            ))}
          </ul>
        </Card>
      )}

      <Card title="Security audit log" actions={<span className="text-xs text-muted">{c.audit_events_total} total events · append-only, hash-chained</span>}>
        {c.recent_audit.length === 0 ? (
          <p className="text-sm text-muted">No security events recorded yet.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-line text-left text-xs uppercase tracking-wide text-muted">
                  <th className="py-2 pr-3">When</th>
                  <th className="py-2 pr-3">Event</th>
                  <th className="py-2 pr-3">Actor</th>
                  <th className="py-2 pr-3">Source</th>
                </tr>
              </thead>
              <tbody>
                {c.recent_audit.map((e) => {
                  const meta = EVENT_META[e.event_type] ?? { label: e.event_type, icon: '•' }
                  return (
                    <tr key={e.id} className="border-b border-line/50">
                      <td className="py-2 pr-3 whitespace-nowrap text-muted">{formatDateTime(e.at)}</td>
                      <td className="py-2 pr-3">
                        <span className="mr-1">{meta.icon}</span>{meta.label}
                        {e.severity === 'critical' && <span className="ml-2"><Badge status="critical" /></span>}
                      </td>
                      <td className="py-2 pr-3">{e.actor_email ?? (e.session_role ? `(${e.session_role})` : '—')}</td>
                      <td className="py-2 pr-3 whitespace-nowrap text-muted">{e.ip ?? '—'}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <Modal title={c.lockdown ? 'Lift security lockdown' : 'Engage security lockdown'} open={lockOpen} onClose={() => setLockOpen(false)}>
        <p className="text-sm text-muted">
          {c.lockdown
            ? 'This re-enables account and role changes.'
            : 'This freezes all account creation and role/permission changes immediately. Backups and jobs keep running. Use it the moment you suspect a compromise.'}
        </p>
        <Field label="Reason (recorded in the audit log)" className="mt-4">
          <input
            className="w-full rounded-lg border border-line bg-surface px-3 py-2 text-sm"
            value={reason} onChange={(e) => setReason(e.target.value)}
            placeholder={c.lockdown ? 'all clear' : 'suspected intrusion'}
          />
        </Field>
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="secondary" onClick={() => setLockOpen(false)}>Cancel</Button>
          <Button variant={c.lockdown ? 'primary' : 'danger'} onClick={() => lock.mutate(!c.lockdown)} disabled={lock.isPending}>
            {lock.isPending ? 'Working…' : c.lockdown ? 'Lift lockdown' : 'Engage lockdown'}
          </Button>
        </div>
        {err && <p className="mt-3 text-sm text-danger">{err}</p>}
      </Modal>
    </div>
  )
}

/** The computed Technology/security playbook metrics (MFA %, incidents, POD OCR
 * success…) — the same numbers that now answer the C-suite playbook. */
function TechMetricsCard() {
  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['security-scorecard'],
    queryFn: securityScorecard,
    refetchInterval: 300_000,
  })
  if (isLoading) return null
  if (error) return <Card title="Security metrics"><LoadError error={error} onRetry={refetch} /></Card>
  const s = data!
  const pct = (v: number | null) => (v == null ? '—' : `${v}%`)
  const tiles: [string, string, boolean, boolean][] = [
    ['MFA coverage', `${pct(s.mfa_coverage_pct)}`, (s.mfa_coverage_pct ?? 0) > 0, false],
    ['Open critical security', String(s.open_critical_security), s.open_critical_security === 0, s.open_critical_security > 0],
    ['Cyber incidents (30d)', String(s.cyber_incidents_30d), s.cyber_incidents_30d === 0, false],
    ['Honeypot hits (30d)', String(s.honeypot_hits_30d), s.honeypot_hits_30d === 0, s.honeypot_hits_30d > 0],
    ['Data recon exceptions (7d)', String(s.data_recon_exceptions_7d), s.data_recon_exceptions_7d === 0, false],
    ['POD OCR success', pct(s.pod_ocr_success_pct), (s.pod_ocr_success_pct ?? 0) >= 90, false],
  ]
  return (
    <Card title="Security metrics" actions={<span className="text-xs text-muted">feeds the C-suite playbook</span>}>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        {tiles.map(([l, v, ok, warn]) => <Stat key={l} label={l} value={v} ok={ok} warn={warn} />)}
      </div>
    </Card>
  )
}


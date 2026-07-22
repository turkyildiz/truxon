/** Two-factor authentication (TOTP) self-service — enroll an authenticator app
 * (QR + manual secret), verify a 6-digit code, list/remove verified factors.
 * Shared by the admin Security console and every office user's Account page.
 * Dark-launch posture: opt-in; sign-in is NOT gated on MFA yet. */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { mfaEnrollTotp, mfaListFactors, mfaUnenroll, mfaVerifyTotp, type MfaEnrollment } from '../data'
import { errorMessage } from '../supabase'
import { Badge, Button, Card, Field, LoadError, formatDateTime } from './ui'

export default function MfaCard() {
  const qc = useQueryClient()
  const { data: factors = [], isLoading, error, refetch } = useQuery({
    queryKey: ['mfa-factors'],
    queryFn: mfaListFactors,
  })
  const [enroll, setEnroll] = useState<MfaEnrollment | null>(null)
  const [code, setCode] = useState('')
  const [err, setErr] = useState('')

  const begin = useMutation({
    mutationFn: () => mfaEnrollTotp(),
    onSuccess: (e) => { setEnroll(e); setCode(''); setErr('') },
    onError: (e) => setErr(errorMessage(e)),
  })
  const verify = useMutation({
    mutationFn: () => mfaVerifyTotp(enroll!.factorId, code),
    onSuccess: () => { setEnroll(null); setCode(''); setErr(''); qc.invalidateQueries({ queryKey: ['mfa-factors'] }) },
    onError: (e) => setErr(errorMessage(e)),
  })
  const remove = useMutation({
    mutationFn: (id: string) => mfaUnenroll(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['mfa-factors'] }),
    onError: (e) => setErr(errorMessage(e)),
  })

  const verified = factors.filter((f) => f.status === 'verified')

  return (
    <Card title="Two-factor authentication (TOTP)" actions={<Badge status={verified.length > 0 ? 'active' : 'inactive'} />}>
      {isLoading ? (
        <p className="text-sm text-muted">Loading factors…</p>
      ) : error ? (
        <LoadError error={error} onRetry={refetch} />
      ) : (
        <div className="space-y-4">
          <p className="text-sm text-muted">
            Add an authenticator app (Google Authenticator, 1Password, Authy…) as a second factor.
            This is opt-in today — sign-in isn't blocked without it yet.
          </p>

          {verified.length > 0 && (
            <ul className="divide-y divide-line rounded-lg border border-line">
              {verified.map((f) => (
                <li key={f.id} className="flex items-center justify-between gap-3 px-3 py-2 text-sm">
                  <span>🔐 {f.friendly_name || 'Authenticator app'} <span className="text-xs text-muted">· enrolled {formatDateTime(f.created_at)}</span></span>
                  <Button variant="secondary" onClick={() => remove.mutate(f.id)} disabled={remove.isPending}>Remove</Button>
                </li>
              ))}
            </ul>
          )}

          {!enroll ? (
            <Button onClick={() => begin.mutate()} disabled={begin.isPending}>
              {begin.isPending ? 'Starting…' : verified.length > 0 ? 'Add another authenticator' : 'Enable authenticator app'}
            </Button>
          ) : (
            <div className="rounded-lg border border-line bg-surface p-4">
              <p className="mb-3 text-sm font-medium">Scan this QR in your authenticator app, then enter the 6-digit code.</p>
              <div className="flex flex-col gap-4 sm:flex-row sm:items-center">
                <img src={enroll.qrCode} alt="TOTP QR code" className="h-44 w-44 rounded bg-white p-2" />
                <div className="space-y-3">
                  <div className="text-xs text-muted">
                    Can't scan? Enter this secret manually:
                    <code className="mt-1 block break-all rounded bg-surface-2 px-2 py-1 font-mono text-[11px]">{enroll.secret}</code>
                  </div>
                  <Field label="6-digit code">
                    <input
                      className="w-40 rounded-lg border border-line bg-surface px-3 py-2 font-mono text-lg tracking-widest"
                      value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
                      inputMode="numeric" placeholder="000000" autoFocus
                    />
                  </Field>
                  <div className="flex gap-2">
                    <Button onClick={() => verify.mutate()} disabled={code.length !== 6 || verify.isPending}>
                      {verify.isPending ? 'Verifying…' : 'Verify & enable'}
                    </Button>
                    <Button variant="secondary" onClick={() => { setEnroll(null); setErr('') }}>Cancel</Button>
                  </div>
                </div>
              </div>
            </div>
          )}
          {err && <p className="text-sm text-danger">{err}</p>}
        </div>
      )}
    </Card>
  )
}

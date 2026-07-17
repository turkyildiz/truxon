import { useState, type FormEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../auth'
import LanguageSwitcher from '../components/LanguageSwitcher'
import { Button, Field, Input } from '../components/ui'
import { errorMessage } from '../supabase'

export default function Login() {
  const { user, login } = useAuth()
  const { t } = useTranslation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  if (user) return <Navigate to="/dashboard" replace />

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError('')
    try {
      await login(email, password)
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-navy-900 p-4">
      <form onSubmit={onSubmit} className="w-full max-w-sm rounded-2xl bg-surface p-8 shadow-2xl">
        <div className="mb-6 text-center">
          <img src="/brand/truxon-icon-color.svg" alt="Truxon" className="mx-auto h-14 w-14" />
          <h1 className="mt-2 text-2xl font-bold text-body">Truxon</h1>
          <p className="text-sm text-muted">{t('login.subtitle')}</p>
        </div>
        <div className="space-y-4">
          <Field label={t('login.email')}>
            <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoFocus autoComplete="username" />
          </Field>
          <Field label={t('login.password')}>
            <Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" />
          </Field>
          {error && <p className="text-sm text-red-600">{error}</p>}
          <Button type="submit" disabled={busy || !email || !password} className="w-full">
            {busy ? t('login.signingIn') : t('login.signIn')}
          </Button>
        </div>
        <div className="mt-6 flex justify-center">
          <LanguageSwitcher />
        </div>
      </form>
    </div>
  )
}

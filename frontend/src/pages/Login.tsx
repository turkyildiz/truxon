import { useState, type FormEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { errorMessage } from '../api'
import { useAuth } from '../auth'
import { Button, Field, Input } from '../components/ui'

export default function Login() {
  const { user, login } = useAuth()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  if (user) return <Navigate to="/" replace />

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError('')
    try {
      await login(username, password)
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-navy-900 p-4">
      <form onSubmit={onSubmit} className="w-full max-w-sm rounded-2xl bg-white p-8 shadow-2xl">
        <div className="mb-6 text-center">
          <div className="text-4xl">🚛</div>
          <h1 className="mt-2 text-2xl font-bold text-navy-800">TrucksOn</h1>
          <p className="text-sm text-slate-500">Transportation Management System</p>
        </div>
        <div className="space-y-4">
          <Field label="Username">
            <Input value={username} onChange={(e) => setUsername(e.target.value)} autoFocus autoComplete="username" />
          </Field>
          <Field label="Password">
            <Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" />
          </Field>
          {error && <p className="text-sm text-red-600">{error}</p>}
          <Button type="submit" disabled={busy || !username || !password} className="w-full">
            {busy ? 'Signing in…' : 'Sign in'}
          </Button>
        </div>
      </form>
    </div>
  )
}

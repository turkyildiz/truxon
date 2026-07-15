import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { api } from './api'
import type { User } from './types'

interface AuthState {
  user: User | null
  loading: boolean
  login: (username: string, password: string) => Promise<void>
  logout: () => void
}

const AuthContext = createContext<AuthState>(null!)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!localStorage.getItem('token')) {
      setLoading(false)
      return
    }
    api
      .get<User>('/auth/me')
      .then((res) => setUser(res.data))
      .catch(() => localStorage.removeItem('token'))
      .finally(() => setLoading(false))
  }, [])

  async function login(username: string, password: string) {
    const form = new URLSearchParams({ username, password })
    const res = await api.post('/auth/login', form)
    localStorage.setItem('token', res.data.access_token)
    const me = await api.get<User>('/auth/me')
    setUser(me.data)
  }

  function logout() {
    localStorage.removeItem('token')
    setUser(null)
  }

  return <AuthContext.Provider value={{ user, loading, login, logout }}>{children}</AuthContext.Provider>
}

export const useAuth = () => useContext(AuthContext)

/** Which nav sections each role can see (admin sees everything). */
export const ROLE_MODULES: Record<string, string[]> = {
  admin: ['dashboard', 'loads', 'dispatch', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices', 'users'],
  dispatcher: ['dashboard', 'loads', 'dispatch', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices'],
  accountant: ['dashboard', 'loads', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices'],
  maintenance: ['trucks', 'trailers', 'maintenance'],
  driver: ['dashboard'],
}

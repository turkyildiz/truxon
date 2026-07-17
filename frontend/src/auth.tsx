import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { supabase } from './supabase'
import type { Profile, Role } from './types'

interface AuthState {
  user: Profile | null
  loading: boolean
  login: (email: string, password: string) => Promise<void>
  logout: () => void
}

const AuthContext = createContext<AuthState>(null!)

async function fetchProfile(userId: string): Promise<Profile | null> {
  const { data } = await supabase.from('profiles').select('*').eq('id', userId).single()
  return data
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false

    async function applySession(userId: string | undefined) {
      if (!userId) {
        if (!cancelled) setUser(null)
        return
      }
      const profile = await fetchProfile(userId)
      if (cancelled) return
      if (!profile || !profile.is_active) {
        await supabase.auth.signOut()
        setUser(null)
        return
      }
      setUser(profile)
    }

    supabase.auth.getSession().then(async ({ data }) => {
      await applySession(data.session?.user.id)
      if (!cancelled) setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'SIGNED_OUT') {
        setUser(null)
        return
      }
      // Re-fetch profile on refresh so demotions / deactivations take effect.
      if (event === 'TOKEN_REFRESHED' || event === 'SIGNED_IN' || event === 'USER_UPDATED') {
        void applySession(session?.user.id)
      }
    })
    return () => {
      cancelled = true
      sub.subscription.unsubscribe()
    }
  }, [])

  async function login(email: string, password: string) {
    const { data, error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw error
    const profile = await fetchProfile(data.user.id)
    if (!profile || !profile.is_active) {
      await supabase.auth.signOut()
      throw new Error('Account is disabled')
    }
    setUser(profile)
  }

  function logout() {
    supabase.auth.signOut()
    setUser(null)
  }

  return <AuthContext.Provider value={{ user, loading, login, logout }}>{children}</AuthContext.Provider>
}

export const useAuth = () => useContext(AuthContext)

/** Which nav sections each role can see (admin sees everything). */
export const ROLE_MODULES: Record<Role | string, string[]> = {
  admin: ['dashboard', 'loads', 'dispatch', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices', 'users', 'settings'],
  dispatcher: ['dashboard', 'loads', 'dispatch', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices'],
  accountant: ['dashboard', 'loads', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices'],
  maintenance: ['trucks', 'trailers', 'maintenance'],
  driver: ['dashboard'],
}

/** Map app route prefixes to ROLE_MODULES keys. */
export const ROUTE_MODULE: { prefix: string; module: string }[] = [
  { prefix: '/dashboard', module: 'dashboard' },
  { prefix: '/loads', module: 'loads' },
  { prefix: '/dispatch', module: 'dispatch' },
  { prefix: '/customers', module: 'customers' },
  { prefix: '/drivers', module: 'drivers' },
  { prefix: '/trucks', module: 'trucks' },
  { prefix: '/trailers', module: 'trailers' },
  { prefix: '/maintenance', module: 'maintenance' },
  { prefix: '/reports', module: 'reports' },
  { prefix: '/invoices', module: 'invoices' },
  { prefix: '/users', module: 'users' },
  { prefix: '/settings', module: 'settings' },
]

export function moduleForPath(pathname: string): string | null {
  const hit = ROUTE_MODULE.find((r) => pathname === r.prefix || pathname.startsWith(r.prefix + '/'))
  return hit?.module ?? null
}

export function roleCanAccess(role: string, module: string): boolean {
  if (role === 'admin') return true
  return (ROLE_MODULES[role] ?? []).includes(module)
}

export function homePathForRole(role: string): string {
  const mods = ROLE_MODULES[role] ?? ['dashboard']
  const first = mods[0] ?? 'dashboard'
  return `/${first}`
}

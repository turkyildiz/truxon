import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { supabase } from './supabase'
import type { Profile } from './types'

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
    supabase.auth.getSession().then(async ({ data }) => {
      if (data.session) setUser(await fetchProfile(data.session.user.id))
      setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'SIGNED_OUT') setUser(null)
      // SIGNED_IN is handled by login() so the UI waits for the profile.
      if (event === 'TOKEN_REFRESHED' && !session) setUser(null)
    })
    return () => sub.subscription.unsubscribe()
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
export const ROLE_MODULES: Record<string, string[]> = {
  admin: ['dashboard', 'loads', 'dispatch', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices', 'users'],
  dispatcher: ['dashboard', 'loads', 'dispatch', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices'],
  accountant: ['dashboard', 'loads', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices'],
  maintenance: ['trucks', 'trailers', 'maintenance'],
  driver: ['dashboard'],
}

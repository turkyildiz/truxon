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

/** null = the profile genuinely doesn't exist; throws on fetch failure so a
 * network blip is never mistaken for a disabled account. */
async function fetchProfile(userId: string): Promise<Profile | null> {
  const { data, error } = await supabase.from('profiles').select('*').eq('id', userId).maybeSingle()
  if (error) throw new Error(error.message)
  return data
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      if (data.session) {
        try {
          setUser(await fetchProfile(data.session.user.id))
        } catch {
          // Transient failure restoring the session — retry once before
          // falling back to the login screen.
          try {
            setUser(await fetchProfile(data.session.user.id))
          } catch {
            /* leave user null; Protected routes redirect to /login */
          }
        }
      }
      setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'SIGNED_OUT') {
        setUser(null)
        return
      }
      // Re-fetch profile so demotions / deactivations take effect without full reload.
      if ((event === 'TOKEN_REFRESHED' || event === 'USER_UPDATED') && session?.user.id) {
        void fetchProfile(session.user.id)
          .then((profile) => {
            if (!profile || !profile.is_active) {
              void supabase.auth.signOut()
              setUser(null)
            } else {
              setUser(profile)
            }
          })
          .catch(() => {
            /* keep prior profile on transient errors */
          })
      } else if (event === 'TOKEN_REFRESHED' && !session) {
        setUser(null)
      }
    })
    return () => sub.subscription.unsubscribe()
  }, [])

  async function login(email: string, password: string) {
    const { data, error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw error
    let profile: Profile | null
    try {
      profile = await fetchProfile(data.user.id)
    } catch {
      throw new Error('Signed in, but your profile could not be loaded — check your connection and try again.')
    }
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
const DRIVES = ['personal_drive', 'team_drive']
export const ROLE_MODULES: Record<string, string[]> = {
  // Forest ('trux') is available to every position — its capabilities are scoped
  // per role server-side (roleGuidance + RLS), so each person's Forest only sees
  // and does what their job allows.
  admin: ['dashboard', 'trux', 'track', 'loads', 'dispatch', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices', 'fuel', 'tolls', ...DRIVES, 'doc_search', 'users', 'settings'],
  dispatcher: ['dashboard', 'trux', 'track', 'loads', 'dispatch', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices', 'fuel', 'tolls', ...DRIVES, 'doc_search'],
  accountant: ['dashboard', 'trux', 'track', 'loads', 'customers', 'drivers', 'trucks', 'trailers', 'maintenance', 'reports', 'invoices', 'fuel', 'tolls', ...DRIVES, 'doc_search'],
  maintenance: ['dashboard', 'trux', 'trucks', 'trailers', 'maintenance', ...DRIVES],
  driver: ['dashboard', 'trux', ...DRIVES],
}

/** Map app route prefixes to ROLE_MODULES keys. */
export const ROUTE_MODULE: { prefix: string; module: string }[] = [
  { prefix: '/dashboard', module: 'dashboard' },
  { prefix: '/trux', module: 'trux' },
  { prefix: '/forest', module: 'trux' },
  { prefix: '/track', module: 'track' },
  { prefix: '/loads', module: 'loads' },
  { prefix: '/dispatch', module: 'dispatch' },
  { prefix: '/customers', module: 'customers' },
  { prefix: '/drivers', module: 'drivers' },
  { prefix: '/trucks', module: 'trucks' },
  { prefix: '/trailers', module: 'trailers' },
  { prefix: '/maintenance', module: 'maintenance' },
  { prefix: '/reports', module: 'reports' },
  { prefix: '/invoices', module: 'invoices' },
  { prefix: '/fuel', module: 'fuel' },
  { prefix: '/tolls', module: 'tolls' },
  { prefix: '/personal-drive', module: 'personal_drive' },
  { prefix: '/team-drive', module: 'team_drive' },
  { prefix: '/doc-search', module: 'doc_search' },
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
  if (first === 'personal_drive') return '/personal-drive'
  if (first === 'team_drive') return '/team-drive'
  return `/${first}`
}

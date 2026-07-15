import { useEffect, useRef, useState } from 'react'
import { NavLink, Outlet, useNavigate } from 'react-router-dom'
import { ROLE_MODULES, useAuth } from '../auth'
import { globalSearch } from '../data'
import type { SearchResults } from '../types'

const NAV_ITEMS: { key: string; to: string; label: string; icon: string }[] = [
  { key: 'dashboard', to: '/', label: 'Dashboard', icon: '📊' },
  { key: 'loads', to: '/loads', label: 'Loads', icon: '📦' },
  { key: 'dispatch', to: '/dispatch', label: 'Dispatch', icon: '🚚' },
  { key: 'customers', to: '/customers', label: 'Customers', icon: '🏢' },
  { key: 'drivers', to: '/drivers', label: 'Drivers', icon: '🪪' },
  { key: 'trucks', to: '/trucks', label: 'Trucks', icon: '🚛' },
  { key: 'trailers', to: '/trailers', label: 'Trailers', icon: '🚋' },
  { key: 'maintenance', to: '/maintenance', label: 'Maintenance', icon: '🔧' },
  { key: 'reports', to: '/reports', label: 'Accounting', icon: '🧾' },
  { key: 'invoices', to: '/invoices', label: 'Invoices', icon: '💵' },
  { key: 'users', to: '/users', label: 'Users', icon: '👤' },
]

function GlobalSearch() {
  const [q, setQ] = useState('')
  const [results, setResults] = useState<SearchResults | null>(null)
  const navigate = useNavigate()
  const boxRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (q.trim().length < 2) {
      setResults(null)
      return
    }
    const t = setTimeout(() => {
      globalSearch(q).then(setResults).catch(() => {})
    }, 250)
    return () => clearTimeout(t)
  }, [q])

  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (!boxRef.current?.contains(e.target as Node)) setResults(null)
    }
    document.addEventListener('click', onClick)
    return () => document.removeEventListener('click', onClick)
  }, [])

  function go(path: string) {
    setResults(null)
    setQ('')
    navigate(path)
  }

  const sections: { title: string; items: { id: number; label: string }[]; path: (id: number) => string }[] = results
    ? [
        { title: 'Loads', items: results.loads, path: (id) => `/loads/${id}` },
        { title: 'Customers', items: results.customers, path: () => '/customers' },
        { title: 'Drivers', items: results.drivers, path: () => '/drivers' },
        { title: 'Trucks', items: results.trucks, path: () => '/trucks' },
      ]
    : []

  return (
    <div className="relative w-full max-w-md" ref={boxRef}>
      <input
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Search loads, customers, drivers, trucks…"
        className="w-full rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm focus:border-navy-600 focus:outline-none"
      />
      {results && (
        <div className="absolute top-full z-40 mt-1 w-full rounded-lg border border-slate-200 bg-white shadow-lg">
          {sections.every((s) => s.items.length === 0) && <div className="p-3 text-sm text-slate-500">No results</div>}
          {sections.map(
            (s) =>
              s.items.length > 0 && (
                <div key={s.title} className="border-b border-slate-100 last:border-0">
                  <div className="px-3 pt-2 text-xs font-semibold uppercase text-slate-400">{s.title}</div>
                  {s.items.map((item) => (
                    <button
                      key={item.id}
                      onClick={() => go(s.path(item.id))}
                      className="block w-full px-3 py-2 text-left text-sm hover:bg-slate-50"
                    >
                      {item.label}
                    </button>
                  ))}
                </div>
              ),
          )}
        </div>
      )}
    </div>
  )
}

export default function Layout() {
  const { user, logout } = useAuth()
  const [menuOpen, setMenuOpen] = useState(false)
  const allowed = ROLE_MODULES[user?.role ?? 'driver'] ?? []
  const items = NAV_ITEMS.filter((i) => allowed.includes(i.key))

  return (
    <div className="flex min-h-screen">
      {/* Sidebar — collapses behind a hamburger on tablet portrait */}
      <aside
        className={`fixed inset-y-0 left-0 z-30 w-60 transform bg-navy-900 text-white transition-transform lg:static lg:translate-x-0 ${menuOpen ? 'translate-x-0' : '-translate-x-full'}`}
      >
        <div className="flex items-center gap-2 px-5 py-5">
          <span className="text-2xl">🚛</span>
          <span className="text-xl font-bold tracking-wide">TrucksOn</span>
        </div>
        <nav className="mt-2 space-y-1 px-3">
          {items.map((item) => (
            <NavLink
              key={item.key}
              to={item.to}
              end={item.to === '/'}
              onClick={() => setMenuOpen(false)}
              className={({ isActive }) =>
                `flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors ${
                  isActive ? 'bg-navy-700 text-white' : 'text-navy-100 hover:bg-navy-800'
                }`
              }
            >
              <span>{item.icon}</span>
              {item.label}
            </NavLink>
          ))}
        </nav>
      </aside>
      {menuOpen && <div className="fixed inset-0 z-20 bg-black/30 lg:hidden" onClick={() => setMenuOpen(false)} />}

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-10 flex items-center gap-4 border-b border-slate-200 bg-white px-4 py-3">
          <button className="rounded-lg border border-slate-300 px-3 py-2 text-sm lg:hidden" onClick={() => setMenuOpen(true)}>
            ☰
          </button>
          <GlobalSearch />
          <div className="ml-auto flex items-center gap-3">
            <div className="hidden text-right sm:block">
              <div className="text-sm font-medium">{user?.full_name || user?.username}</div>
              <div className="text-xs capitalize text-slate-500">{user?.role}</div>
            </div>
            <button onClick={logout} className="rounded-lg border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
              Sign out
            </button>
          </div>
        </header>
        <main className="flex-1 p-4 lg:p-6">
          <Outlet />
        </main>
      </div>
    </div>
  )
}

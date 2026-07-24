import { Suspense, useEffect, useRef, useState, type FormEvent } from 'react'
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import ErrorBoundary from './ErrorBoundary'
import PageLoader from './PageLoader'
import { ROLE_MODULES, useAuth } from '../auth'
import { globalSearch } from '../data'
import { initPerf } from '../perf'
import { errorMessage, supabase } from '../supabase'
import { useTheme } from '../theme'
import type { SearchResults } from '../types'
import { TruxLauncher } from './TruxChat'
import { Button, Field, Input, Modal } from './ui'

function ChangePasswordModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState('')
  const [done, setDone] = useState(false)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (password !== confirm) {
      setError('Passwords do not match')
      return
    }
    setBusy(true)
    setError('')
    const { error: err } = await supabase.auth.updateUser({ password })
    setBusy(false)
    if (err) setError(errorMessage(err))
    else {
      setDone(true)
      setPassword('')
      setConfirm('')
      setTimeout(() => {
        setDone(false)
        onClose()
      }, 1500)
    }
  }

  return (
    <Modal title="Change Password" open={open} onClose={onClose}>
      {done ? (
        <p className="py-4 text-center font-medium text-green-600">✓ Password updated</p>
      ) : (
        <form onSubmit={onSubmit} className="space-y-4">
          <Field label="New Password (min 8 characters)">
            <Input type="password" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" />
          </Field>
          <Field label="Confirm New Password">
            <Input type="password" required value={confirm} onChange={(e) => setConfirm(e.target.value)} autoComplete="new-password" />
          </Field>
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex justify-end gap-3">
            <Button type="button" variant="secondary" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={busy || !password}>
              {busy ? 'Saving…' : 'Update Password'}
            </Button>
          </div>
        </form>
      )}
    </Modal>
  )
}

type NavItem = { key: string; to: string; label: string; icon: string }

// Grouped so the sidebar reads as a few sections instead of one long list.
// `title: null` is the ungrouped top item (Dashboard). Role filtering still
// happens per item by key; a group with no visible items is hidden entirely.
const NAV_GROUPS: { title: string | null; items: NavItem[] }[] = [
  { title: null, items: [
    { key: 'dashboard', to: '/dashboard', label: 'Dashboard', icon: '📊' },
    { key: 'trux', to: '/forest', label: 'Forest', icon: '🌲' },
  ] },
  { title: 'Operations', items: [
    { key: 'track', to: '/track', label: 'Track & Trace', icon: '📍' },
    { key: 'radio', to: '/radio', label: 'Radio', icon: '📻' },
    { key: 'loads', to: '/loads', label: 'Loads', icon: '📦' },
    { key: 'dispatch', to: '/dispatch', label: 'Dispatch', icon: '🚚' },
    { key: 'shadow', to: '/shadow', label: 'Forest Shadow', icon: '🕶️' },
    { key: 'customers', to: '/customers', label: 'Customers', icon: '🏢' },
  ] },
  { title: 'Fleet', items: [
    { key: 'drivers', to: '/drivers', label: 'Drivers', icon: '🪪' },
    { key: 'trucks', to: '/trucks', label: 'Trucks', icon: '🚛' },
    { key: 'trailers', to: '/trailers', label: 'Trailers', icon: '🚋' },
    { key: 'maintenance', to: '/maintenance', label: 'Maintenance', icon: '🔧' },
  ] },
  { title: 'Accounting', items: [
    { key: 'reports', to: '/reports', label: 'Weekly Report', icon: '🧾' },
    { key: 'playbook', to: '/playbook', label: 'Playbook', icon: '🎯' },
    { key: 'invoices', to: '/invoices', label: 'Accounting', icon: '💵' },
    { key: 'fuel', to: '/fuel', label: 'Fuel', icon: '⛽' },
    { key: 'tolls', to: '/tolls', label: 'Tolls', icon: '🛣️' },
  ] },
  { title: 'Files', items: [
    { key: 'personal_drive', to: '/personal-drive', label: 'Personal Drive', icon: '📁' },
    { key: 'team_drive', to: '/team-drive', label: 'Team Drive', icon: '🗂️' },
    { key: 'doc_search', to: '/doc-search', label: 'Document Search', icon: '🔎' },
  ] },
  { title: 'Admin', items: [
    { key: 'users', to: '/users', label: 'Users', icon: '👤' },
    { key: 'security', to: '/security', label: 'Security', icon: '🛡️' },
    { key: 'settings', to: '/settings', label: 'Settings', icon: '⚙️' },
  ] },
  { title: null, items: [
    { key: 'account', to: '/account', label: 'My Account', icon: '🔐' },
  ] },
]

function GlobalSearch() {
  const [q, setQ] = useState('')
  const [results, setResults] = useState<SearchResults | null>(null)
  const [failed, setFailed] = useState(false)
  const [active, setActive] = useState(-1)
  const navigate = useNavigate()
  const boxRef = useRef<HTMLDivElement>(null)
  const seq = useRef(0)

  useEffect(() => {
    setFailed(false)
    setActive(-1)
    if (q.trim().length < 2) {
      setResults(null)
      return
    }
    // The seq guard drops out-of-order/failed responses so the dropdown never
    // shows results (or errors) belonging to an earlier query string.
    const mySeq = ++seq.current
    const t = setTimeout(() => {
      globalSearch(q)
        .then((r) => {
          if (seq.current === mySeq) setResults(r)
        })
        .catch(() => {
          if (seq.current === mySeq) {
            setResults(null)
            setFailed(true)
          }
        })
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
    setActive(-1)
    navigate(path)
  }

  // Non-load entities have no detail routes; carrying the search term lets
  // the destination list page pre-filter to the clicked match.
  const carry = `?q=${encodeURIComponent(q.trim())}`
  // R9 #153: documents ride along — each lands on its owning entity's page
  // (loads/customers have detail routes; the rest carry the search term).
  const docPath = (d: { entity_type: string; entity_id: number }) =>
    d.entity_type === 'load' ? `/loads/${d.entity_id}`
    : d.entity_type === 'customer' ? `/customers/${d.entity_id}`
    : d.entity_type === 'driver' ? `/drivers${carry}`
    : d.entity_type === 'truck' ? `/trucks${carry}`
    : d.entity_type === 'trailer' ? `/trailers${carry}`
    : `/maintenance${carry}`
  const sections: { title: string; items: { id: number; label: string }[]; path: (id: number) => string }[] = results
    ? [
        { title: 'Loads', items: results.loads, path: (id) => `/loads/${id}` },
        { title: 'Customers', items: results.customers, path: () => `/customers${carry}` },
        { title: 'Drivers', items: results.drivers, path: () => `/drivers${carry}` },
        { title: 'Trucks', items: results.trucks, path: () => `/trucks${carry}` },
        {
          title: 'Documents',
          items: results.documents ?? [],
          path: (id) => {
            const d = (results.documents ?? []).find((x) => x.id === id)
            return d ? docPath(d) : `/docsearch${carry}`
          },
        },
      ]
    : []

  // Flatten every section's rows into one list so Arrow keys move a single
  // highlight across the whole dropdown; the index maps to each option's id.
  const flat = sections.flatMap((s) => s.items.map((item) => ({ path: s.path(item.id) })))
  const optionId = (i: number) => `global-search-opt-${i}`

  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === 'Escape') {
      setResults(null)
      setQ('')
      setActive(-1)
      return
    }
    if (!flat.length) return
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setActive((i) => (i + 1) % flat.length)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActive((i) => (i <= 0 ? flat.length - 1 : i - 1))
    } else if (e.key === 'Enter') {
      if (active >= 0 && active < flat.length) {
        e.preventDefault()
        go(flat[active].path)
      }
    }
  }

  // Running index across sections, aligned with `flat`, for aria/highlight.
  let idx = -1
  return (
    <div className="relative w-full max-w-md" ref={boxRef}>
      <input
        value={q}
        onChange={(e) => setQ(e.target.value)}
        onKeyDown={onKeyDown}
        role="combobox"
        aria-expanded={!!results}
        aria-controls="global-search-listbox"
        aria-autocomplete="list"
        aria-activedescendant={active >= 0 ? optionId(active) : undefined}
        placeholder="Search loads, customers, drivers, trucks…  ( / )"
        data-global-search
        className="w-full rounded-lg border border-line bg-surface px-4 py-2 text-sm text-body placeholder:text-muted focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/30"
      />
      {failed && (
        <div className="absolute top-full z-40 mt-1 w-full rounded-lg border border-line bg-surface p-3 text-sm text-red-600 shadow-lg">
          Search failed — check your connection and keep typing to retry.
        </div>
      )}
      {results && (
        <div id="global-search-listbox" role="listbox" className="absolute top-full z-40 mt-1 w-full rounded-lg border border-line bg-surface shadow-lg">
          {sections.every((s) => s.items.length === 0) && <div className="p-3 text-sm text-muted">No results</div>}
          {sections.map(
            (s) =>
              s.items.length > 0 && (
                <div key={s.title} className="border-b border-line last:border-0">
                  <div className="px-3 pt-2 text-xs font-semibold uppercase text-muted">{s.title}</div>
                  {s.items.map((item) => {
                    idx += 1
                    const i = idx
                    return (
                      <button
                        key={item.id}
                        id={optionId(i)}
                        role="option"
                        aria-selected={active === i}
                        onMouseEnter={() => setActive(i)}
                        onClick={() => go(s.path(item.id))}
                        className={`block w-full px-3 py-2 text-left text-sm text-body ${active === i ? 'bg-surface-2' : 'hover:bg-surface-2'}`}
                      >
                        {item.label}
                      </button>
                    )
                  })}
                </div>
              ),
          )}
        </div>
      )}
    </div>
  )
}


/** g-then-key navigation + / to focus search (R9 #154). Skips inputs. */
function useKeyboardShortcuts() {
  const navigate = useNavigate()
  useEffect(() => {
    let pendingG = false
    let timer: ReturnType<typeof setTimeout> | null = null
    const GOTO: Record<string, string> = {
      l: '/loads', i: '/invoices', d: '/dispatch', c: '/customers',
      m: '/maintenance', r: '/reports', f: '/fuel', t: '/trux', e: '/trucks',
    }
    const onKey = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable) return
      if (e.metaKey || e.ctrlKey || e.altKey) return
      if (e.key === '/') {
        e.preventDefault()
        document.querySelector<HTMLInputElement>('input[data-global-search]')?.focus()
        return
      }
      if (pendingG && GOTO[e.key]) {
        e.preventDefault()
        navigate(GOTO[e.key])
        pendingG = false
        return
      }
      pendingG = e.key === 'g'
      if (timer) clearTimeout(timer)
      if (pendingG) timer = setTimeout(() => { pendingG = false }, 1200)
    }
    window.addEventListener('keydown', onKey)
    return () => { window.removeEventListener('keydown', onKey); if (timer) clearTimeout(timer) }
  }, [navigate])
}

export default function Layout() {
  useKeyboardShortcuts()
  const { user, logout } = useAuth()
  const { theme, toggle } = useTheme()
  const location = useLocation()
  // R9 #165: start real-user timing once, inside the authenticated shell.
  useEffect(() => { initPerf() }, [])
  const [menuOpen, setMenuOpen] = useState(false)
  const [pwOpen, setPwOpen] = useState(false)
  const allowed = ROLE_MODULES[user?.role ?? 'driver'] ?? []
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>(() => {
    try { return JSON.parse(localStorage.getItem('truxon-nav-collapsed') || '{}') } catch { return {} }
  })
  function toggleGroup(title: string) {
    setCollapsed((c) => {
      const next = { ...c, [title]: !c[title] }
      localStorage.setItem('truxon-nav-collapsed', JSON.stringify(next))
      return next
    })
  }

  return (
    <div className="flex min-h-screen">
      {/* Sidebar — collapses behind a hamburger on tablet portrait */}
      <aside
        className={`fixed inset-y-0 left-0 z-30 w-60 transform bg-navy-900 text-white transition-transform lg:static lg:translate-x-0 ${menuOpen ? 'translate-x-0' : '-translate-x-full'}`}
      >
        <div className="flex items-center px-5 py-5">
          <img src="/brand/truxon-primary-white.png" alt="Truxon" className="h-8 w-auto" />
        </div>
        <nav className="mt-2 space-y-1 px-3">
          {NAV_GROUPS.map((group, gi) => {
            const groupItems = group.items.filter((i) => allowed.includes(i.key))
            if (groupItems.length === 0) return null
            // The group holding the current page always stays open so you can
            // see where you are, even if it was collapsed.
            const hasActive = groupItems.some((i) => location.pathname.startsWith(i.to))
            const isCollapsed = group.title != null && !!collapsed[group.title] && !hasActive
            return (
              <div key={group.title ?? `g${gi}`} className={group.title ? 'pt-3' : ''}>
                {group.title && (
                  <button
                    onClick={() => toggleGroup(group.title!)}
                    className="flex w-full items-center justify-between px-3 pb-1 text-xs font-semibold uppercase tracking-wide text-navy-300 hover:text-white"
                  >
                    <span>{group.title}</span>
                    <span className="text-[10px] leading-none">{isCollapsed ? '▸' : '▾'}</span>
                  </button>
                )}
                {!isCollapsed && groupItems.map((item) => (
                  <NavLink
                    key={item.key}
                    to={item.to}
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
              </div>
            )
          })}
        </nav>
      </aside>
      {menuOpen && <div className="fixed inset-0 z-20 bg-black/30 lg:hidden" onClick={() => setMenuOpen(false)} />}

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-10 flex items-center gap-4 border-b border-line bg-surface px-4 py-3">
          <button className="rounded-lg border border-line px-3 py-2 text-sm lg:hidden" onClick={() => setMenuOpen(true)}>
            ☰
          </button>
          {/* The global_search RPC is gated to office roles — don't show a box that can only fail. */}
          {['admin', 'dispatcher', 'accountant'].includes(user?.role ?? '') && <GlobalSearch />}
          <div className="ml-auto flex items-center gap-3">
            <div className="hidden text-right sm:block">
              <div className="text-sm font-medium text-body">{user?.full_name || user?.username}</div>
              <div className="text-xs capitalize text-muted">{user?.role}</div>
            </div>
            <button
              onClick={toggle}
              title={theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}
              className="rounded-lg border border-line px-3 py-2 text-sm hover:bg-surface-2"
            >
              {theme === 'dark' ? '☀️' : '🌙'}
            </button>
            <button
              onClick={() => setPwOpen(true)}
              title="Change password"
              className="rounded-lg border border-line px-3 py-2 text-sm hover:bg-surface-2"
            >
              🔑
            </button>
            <button onClick={logout} className="rounded-lg border border-line px-3 py-2 text-sm text-body hover:bg-surface-2">
              Sign out
            </button>
          </div>
        </header>
        <main className="flex-1 p-4 lg:p-6">
          <ErrorBoundary key={location.pathname}>
            {/* Suspense sits inside the boundary so a slow/broken lazy chunk
                shows the PageLoader (or, if it throws, the boundary) — never a
                white screen. */}
            <Suspense fallback={<PageLoader />}>
              <Outlet />
            </Suspense>
          </ErrorBoundary>
        </main>
        <TruxLauncher />
        <ChangePasswordModal open={pwOpen} onClose={() => setPwOpen(false)} />
      </div>
    </div>
  )
}

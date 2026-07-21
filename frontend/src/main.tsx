import { StrictMode, Suspense, lazy } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router-dom'
import './index.css'
import { ThemeProvider } from './theme'
import { AuthProvider, homePathForRole, moduleForPath, roleCanAccess, useAuth } from './auth'
import Layout from './components/Layout'
import PageLoader from './components/PageLoader'

// Pages are code-split: each becomes its own chunk so the heavy libraries they
// pull in (recharts, leaflet, jspdf, pdfjs…) no longer weigh down the initial
// load. Layout/PageLoader stay static so the shell renders instantly.
const Landing = lazy(() => import('./pages/Landing'))
const Privacy = lazy(() => import('./pages/Legal').then((m) => ({ default: m.Privacy })))
const Terms = lazy(() => import('./pages/Legal').then((m) => ({ default: m.Terms })))
const Login = lazy(() => import('./pages/Login'))
const Dashboard = lazy(() => import('./pages/Dashboard'))
const Trux = lazy(() => import('./pages/Trux'))
const FleetMap = lazy(() => import('./pages/FleetMap'))
const Loads = lazy(() => import('./pages/Loads'))
const LoadDetail = lazy(() => import('./pages/LoadDetail'))
const CustomerDetail = lazy(() => import('./pages/CustomerDetail'))
const Dispatch = lazy(() => import('./pages/Dispatch'))
const Customers = lazy(() => import('./pages/Customers'))
const Drivers = lazy(() => import('./pages/Drivers'))
const Trucks = lazy(() => import('./pages/Equipment').then((m) => ({ default: m.Trucks })))
const Trailers = lazy(() => import('./pages/Equipment').then((m) => ({ default: m.Trailers })))
const Maintenance = lazy(() => import('./pages/Maintenance'))
const Reports = lazy(() => import('./pages/Reports'))
const Invoices = lazy(() => import('./pages/Invoices'))
const Fuel = lazy(() => import('./pages/Fuel'))
const Tolls = lazy(() => import('./pages/Tolls'))
const Users = lazy(() => import('./pages/Users'))
const Settings = lazy(() => import('./pages/Settings'))
const Drive = lazy(() => import('./pages/Drive'))
const DocSearch = lazy(() => import('./pages/DocSearch'))
const Playbook = lazy(() => import('./pages/Playbook'))
const Shadow = lazy(() => import('./pages/Shadow'))

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, staleTime: 15_000 } },
})

function Protected({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth()
  if (loading) return <div className="flex min-h-screen items-center justify-center text-slate-500">Loading…</div>
  if (!user) return <Navigate to="/login" replace />
  return <>{children}</>
}

/** Role-aware route guard — sidebar alone is not a security boundary. */
function ModuleRoute({ children }: { children: React.ReactNode }) {
  const { user } = useAuth()
  const location = useLocation()
  if (!user) return <Navigate to="/login" replace />
  const mod = moduleForPath(location.pathname)
  if (mod && !roleCanAccess(user.role, mod)) {
    return <Navigate to={homePathForRole(user.role)} replace />
  }
  return <>{children}</>
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider>
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Suspense fallback={<PageLoader />}>
          <Routes>
            <Route path="/" element={<Landing />} />
            <Route path="/privacy" element={<Privacy />} />
            <Route path="/terms" element={<Terms />} />
            <Route path="/login" element={<Login />} />
            <Route
              element={
                <Protected>
                  <ModuleRoute>
                    <Layout />
                  </ModuleRoute>
                </Protected>
              }
            >
              <Route path="/dashboard" element={<Dashboard />} />
              <Route path="/forest" element={<Trux />} />
              {/* legacy path — Trux was renamed Forest (2026-07-20) */}
              <Route path="/trux" element={<Navigate to="/forest" replace />} />
              <Route path="/track" element={<FleetMap />} />
              <Route path="/loads" element={<Loads />} />
              <Route path="/loads/:id" element={<LoadDetail />} />
              <Route path="/dispatch" element={<Dispatch />} />
              <Route path="/customers" element={<Customers />} />
              <Route path="/customers/:id" element={<CustomerDetail />} />
              <Route path="/drivers" element={<Drivers />} />
              <Route path="/trucks" element={<Trucks />} />
              <Route path="/trailers" element={<Trailers />} />
              <Route path="/maintenance" element={<Maintenance />} />
              <Route path="/reports" element={<Reports />} />
              <Route path="/invoices" element={<Invoices />} />
              <Route path="/fuel" element={<Fuel />} />
              <Route path="/tolls" element={<Tolls />} />
              <Route path="/personal-drive" element={<Drive drive="personal" />} />
              <Route path="/team-drive" element={<Drive drive="team" />} />
              <Route path="/doc-search" element={<DocSearch />} />
              <Route path="/playbook" element={<Playbook />} />
              <Route path="/shadow" element={<Shadow />} />
              <Route path="/users" element={<Users />} />
              <Route path="/settings" element={<Settings />} />
            </Route>
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
          </Suspense>
        </BrowserRouter>
      </AuthProvider>
    </QueryClientProvider>
    </ThemeProvider>
  </StrictMode>,
)

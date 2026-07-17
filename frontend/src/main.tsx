import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router-dom'
import './index.css'
import './i18n'
import { ThemeProvider } from './theme'
import { AuthProvider, homePathForRole, moduleForPath, roleCanAccess, useAuth } from './auth'
import Layout from './components/Layout'
import Landing from './pages/Landing'
import Login from './pages/Login'
import Dashboard from './pages/Dashboard'
import FleetMap from './pages/FleetMap'
import Loads from './pages/Loads'
import LoadDetail from './pages/LoadDetail'
import Dispatch from './pages/Dispatch'
import Customers from './pages/Customers'
import Drivers from './pages/Drivers'
import { Trailers, Trucks } from './pages/Equipment'
import Maintenance from './pages/Maintenance'
import Reports from './pages/Reports'
import Invoices from './pages/Invoices'
import Users from './pages/Users'
import Settings from './pages/Settings'
import Drive from './pages/Drive'

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
          <Routes>
            <Route path="/" element={<Landing />} />
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
              <Route path="/track" element={<FleetMap />} />
              <Route path="/loads" element={<Loads />} />
              <Route path="/loads/:id" element={<LoadDetail />} />
              <Route path="/dispatch" element={<Dispatch />} />
              <Route path="/customers" element={<Customers />} />
              <Route path="/drivers" element={<Drivers />} />
              <Route path="/trucks" element={<Trucks />} />
              <Route path="/trailers" element={<Trailers />} />
              <Route path="/maintenance" element={<Maintenance />} />
              <Route path="/reports" element={<Reports />} />
              <Route path="/invoices" element={<Invoices />} />
              <Route path="/personal-drive" element={<Drive drive="personal" />} />
              <Route path="/team-drive" element={<Drive drive="team" />} />
              <Route path="/users" element={<Users />} />
              <Route path="/settings" element={<Settings />} />
            </Route>
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </BrowserRouter>
      </AuthProvider>
    </QueryClientProvider>
    </ThemeProvider>
  </StrictMode>,
)

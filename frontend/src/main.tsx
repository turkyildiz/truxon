import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import './index.css'
import { AuthProvider, useAuth } from './auth'
import Layout from './components/Layout'
import Login from './pages/Login'
import Dashboard from './pages/Dashboard'
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

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, staleTime: 15_000 } },
})

function Protected({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth()
  if (loading) return <div className="flex min-h-screen items-center justify-center text-slate-500">Loading…</div>
  if (!user) return <Navigate to="/login" replace />
  return <>{children}</>
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<Login />} />
            <Route
              element={
                <Protected>
                  <Layout />
                </Protected>
              }
            >
              <Route path="/" element={<Dashboard />} />
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
              <Route path="/users" element={<Users />} />
            </Route>
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </BrowserRouter>
      </AuthProvider>
    </QueryClientProvider>
  </StrictMode>,
)

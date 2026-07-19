import { useQuery } from '@tanstack/react-query'
import { listCustomers, listDrivers, trailersApi, trucksApi } from './data'

/** Shared loader for the customer/driver/truck/trailer dropdown options used by
 * the dispatch and load-edit forms. Returns the four lists plus a combined
 * error flag and a retry that refetches only the failed queries. */
export function useReferenceData() {
  const customersQ = useQuery({ queryKey: ['customers', ''], queryFn: () => listCustomers() })
  const driversQ = useQuery({ queryKey: ['drivers', ''], queryFn: () => listDrivers() })
  const trucksQ = useQuery({ queryKey: ['trucks', ''], queryFn: () => trucksApi.list() })
  const trailersQ = useQuery({ queryKey: ['trailers', ''], queryFn: () => trailersApi.list() })
  const queries = [customersQ, driversQ, trucksQ, trailersQ]
  return {
    customers: customersQ.data ?? [],
    drivers: driversQ.data ?? [],
    trucks: trucksQ.data ?? [],
    trailers: trailersQ.data ?? [],
    isError: queries.some((q) => q.isError),
    retry: () => queries.forEach((q) => q.isError && q.refetch()),
  }
}

/** The "some dropdown options failed to load" retry banner shared by the
 * dispatch and load-edit forms. Renders nothing when there is no error. */
export function ReferenceDataBanner({ show, onRetry }: { show: boolean; onRetry: () => void }) {
  if (!show) return null
  return (
    <p className="mb-3 rounded-lg bg-red-500/10 p-3 text-sm text-red-600 dark:text-red-300">
      Some dropdown options failed to load — check your connection and{' '}
      <button type="button" className="font-medium underline" onClick={onRetry}>
        retry
      </button>
      .
    </p>
  )
}

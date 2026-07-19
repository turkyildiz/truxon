/** Suspense fallback shown while a lazily-loaded route chunk is fetched —
 * a centered, muted spinner that matches the app's quiet loading style. */
export default function PageLoader() {
  return (
    <div className="flex min-h-[40vh] items-center justify-center text-muted" role="status" aria-live="polite">
      <span className="h-6 w-6 animate-spin rounded-full border-2 border-line border-t-brand" />
      <span className="sr-only">Loading…</span>
    </div>
  )
}

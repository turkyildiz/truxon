// R9 #165: real-user timing. Captures TTFB/FCP/LCP from the Performance API
// and per-route render time, batches them, and flushes on page hide via the
// authenticated Supabase client. Best-effort — a hard-killed tab may not
// flush its last batch, and that's fine (the report says so). No IP, no UA.
import { supabase } from './supabase'

type Metric = 'ttfb' | 'fcp' | 'lcp' | 'route' | 'session_s'
interface Sample { session_id: string; path: string; metric: Metric; value: number }

// One id per tab load; cheap and collision-safe enough for grouping sessions.
const sessionId = `${Date.now().toString(36)}-${Math.floor(performance.now())}-${Math.round(performance.timeOrigin % 1e6)}`
const sessionStart = performance.now()
let buffer: Sample[] = []
let started = false

function push(metric: Metric, value: number, path = location.pathname) {
  if (!Number.isFinite(value) || value < 0) return
  buffer.push({ session_id: sessionId, path, metric, value: Math.round(value) })
}

async function flush() {
  if (buffer.length === 0) return
  const batch = buffer
  buffer = []
  // Only report for signed-in users; the table is RLS-gated to user_id.
  const { data } = await supabase.auth.getSession()
  if (!data.session) return
  const rows = batch.map((s) => ({ ...s, user_id: data.session!.user.id }))
  await supabase.from('web_vitals').insert(rows)
}

/** Wire once from the app shell after auth is available. */
export function initPerf() {
  if (started || typeof window === 'undefined' || !('performance' in window)) return
  started = true

  // Navigation timing (TTFB) + first paint, once the load settles.
  const onLoad = () => {
    const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined
    if (nav) push('ttfb', nav.responseStart)
    const fcp = performance.getEntriesByName('first-contentful-paint')[0]
    if (fcp) push('fcp', fcp.startTime)
  }
  if (document.readyState === 'complete') onLoad()
  else window.addEventListener('load', onLoad, { once: true })

  // Largest Contentful Paint — take the last reported value before hide.
  try {
    const po = new PerformanceObserver((list) => {
      const entries = list.getEntries()
      const last = entries[entries.length - 1]
      if (last) push('lcp', last.startTime)
    })
    po.observe({ type: 'largest-contentful-paint', buffered: true })
  } catch { /* browser without the LCP observer — skip it */ }

  // Flush on hide (the reliable "page is going away" signal) + session length.
  const onHide = () => {
    if (document.visibilityState === 'hidden') {
      push('session_s', (performance.now() - sessionStart) / 1000, '')
      void flush()
    }
  }
  document.addEventListener('visibilitychange', onHide)
}

/** Call on each client-side route change with the ms the route took to render. */
export function reportRoute(path: string, ms: number) {
  push('route', ms, path)
}

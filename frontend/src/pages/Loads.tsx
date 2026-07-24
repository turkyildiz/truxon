import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Badge, Button, Card, compareValues, formatDateTime, Input, LoadError, money, Select, type SortState, Table, toggleSort } from '../components/ui'
import { changeLoadStatus, listCustomers, listDrivers, listLoads, listMissingPods, loadEtaRisk, updateLoad } from '../data'
import { errorMessage } from '../supabase'
import { LOAD_STATUSES, type Load } from '../types'

const ALL_STATUSES = [...LOAD_STATUSES, 'cancelled' as const]

// R9 #156/#157: saved views + column chooser, persisted per browser.
const VIEWS_KEY = 'truxon.views.loads'
const COLS_KEY = 'truxon.cols.loads'
interface SavedView {
  name: string
  q: string
  statuses: string[]
  awaitingOnly: boolean
  customerId: string
  driverId: string
  dateFrom: string
  dateTo: string
}
const HIDEABLE: { key: string; label: string }[] = [
  { key: 'customer', label: 'Customer' },
  { key: 'pickup', label: 'Pickup' },
  { key: 'delivery', label: 'Delivery' },
  { key: 'driver', label: 'Driver' },
  { key: 'rate', label: 'Rate' },
  { key: 'rpm', label: '$/mi' },
]
function readJson<T>(key: string, fallback: T): T {
  try { return JSON.parse(localStorage.getItem(key) ?? '') as T } catch { return fallback }
}

/** Delivered/billed loads with no POD on file — money that can stall. */
function MissingPodsBanner() {
  const [open, setOpen] = useState(false)
  const q = useQuery({ queryKey: ['missing-pods', 45], queryFn: () => listMissingPods(45), staleTime: 60_000 })
  const rows = q.data ?? []
  if (rows.length === 0) return null
  return (
    <div className="rounded-xl border border-amber-500/40 bg-amber-500/10 px-4 py-3">
      <button onClick={() => setOpen((v) => !v)} className="flex w-full items-center justify-between text-left">
        <span className="text-sm font-semibold text-amber-700 dark:text-amber-300">
          📄 {rows.length} delivered load{rows.length === 1 ? '' : 's'} missing a POD (last 45 days) — brokers won't pay without it
        </span>
        <span className="text-xs text-amber-700 dark:text-amber-300">{open ? 'hide' : 'show'}</span>
      </button>
      {open && (
        <div className="mt-2 max-h-56 space-y-1 overflow-y-auto">
          {rows.slice(0, 60).map((r) => (
            <Link key={r.load_id} to={`/loads/${r.load_id}`} className="flex items-center justify-between rounded px-2 py-1 text-sm hover:bg-amber-500/10">
              <span className="font-medium text-brand">#{r.load_number}</span>
              <span className="truncate px-2 text-muted">{r.customer ?? '—'}</span>
              <span className="text-xs capitalize text-muted">{r.status}</span>
            </Link>
          ))}
        </div>
      )}
    </div>
  )
}

export default function Loads() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [q, setQ] = useState('')
  // R9 #159: inline edits on the list — status advance + driver swap without
  // opening the detail page. Errors surface under the row that caused them.
  const [rowErr, setRowErr] = useState<Record<number, string>>({})
  const advance = useMutation({
    mutationFn: ({ id, status }: { id: number; status: Load['status'] }) => changeLoadStatus(id, status),
    onSuccess: (_d, v) => { setRowErr((p) => ({ ...p, [v.id]: '' })); qc.invalidateQueries({ queryKey: ['loads'] }) },
    onError: (err, v) => setRowErr((p) => ({ ...p, [v.id]: errorMessage(err) })),
  })
  const swapDriver = useMutation({
    mutationFn: ({ id, driverId }: { id: number; driverId: string }) =>
      updateLoad(id, { driver_id: driverId ? Number(driverId) : null }),
    onSuccess: (_d, v) => { setRowErr((p) => ({ ...p, [v.id]: '' })); qc.invalidateQueries({ queryKey: ['loads'] }) },
    onError: (err, v) => setRowErr((p) => ({ ...p, [v.id]: errorMessage(err) })),
  })
  // Status toggles (crew feedback): one switch per status, multi-select;
  // the landing view opens with In Transit on. All off = show everything.
  const [statuses, setStatuses] = useState<Set<string>>(() => new Set(['in_transit']))
  const toggleStatus = (s: string) =>
    setStatuses((prev) => {
      const next = new Set(prev)
      if (next.has(s)) next.delete(s)
      else next.add(s)
      return next
    })
  const statusList = [...statuses].sort()
  const [awaitingOnly, setAwaitingOnly] = useState(false)
  // deep-link support: /loads?customer=<id> pre-filters (Customer detail links here)
  const initialCustomer = new URLSearchParams(window.location.search).get('customer') ?? ''
  const [customerId, setCustomerId] = useState(initialCustomer)
  const [driverId, setDriverId] = useState('')
  const [dateFrom, setDateFrom] = useState('')
  const [dateTo, setDateTo] = useState('')

  // R9 #156: saved views — name the current filter set, apply it in one click.
  const [views, setViews] = useState<SavedView[]>(() => readJson<SavedView[]>(VIEWS_KEY, []))
  const [savingView, setSavingView] = useState(false)
  const [viewName, setViewName] = useState('')
  const persistViews = (next: SavedView[]) => { setViews(next); localStorage.setItem(VIEWS_KEY, JSON.stringify(next)) }
  const saveCurrentView = () => {
    const name = viewName.trim()
    if (!name) return
    const v: SavedView = { name, q, statuses: [...statuses], awaitingOnly, customerId, driverId, dateFrom, dateTo }
    persistViews([...views.filter((x) => x.name !== name), v])
    setSavingView(false)
    setViewName('')
  }
  const applyView = (v: SavedView) => {
    setQ(v.q); setStatuses(new Set(v.statuses)); setAwaitingOnly(v.awaitingOnly)
    setCustomerId(v.customerId); setDriverId(v.driverId); setDateFrom(v.dateFrom); setDateTo(v.dateTo)
  }

  // R9 #157: column chooser — hidden columns persist per browser.
  const [hiddenCols, setHiddenCols] = useState<Set<string>>(() => new Set(readJson<string[]>(COLS_KEY, [])))
  const [colsOpen, setColsOpen] = useState(false)
  const toggleCol = (key: string) => {
    const next = new Set(hiddenCols)
    if (next.has(key)) next.delete(key)
    else next.add(key)
    setHiddenCols(next)
    localStorage.setItem(COLS_KEY, JSON.stringify([...next]))
  }
  const show = (key: string) => !hiddenCols.has(key)

  // Include inactive customers — old loads still need to be filterable by them.
  const { data: customers = [] } = useQuery({ queryKey: ['customers-all', ''], queryFn: () => listCustomers(undefined, { includeInactive: true }) })
  const { data: drivers = [] } = useQuery({ queryKey: ['drivers', ''], queryFn: () => listDrivers() })
  // R9 #114: ETA/late-risk badges per rolling load (same feed as the Dispatch card)
  const etaQ = useQuery({ queryKey: ['eta-risk'], queryFn: loadEtaRisk, refetchInterval: 5 * 60_000, retry: false })
  const etaByLoad = useMemo(() => new Map((etaQ.data ?? []).map((r) => [r.load_id, r])), [etaQ.data])
  const loadsQ = useQuery({
    queryKey: ['loads', q, statusList.join(','), awaitingOnly, customerId, driverId, dateFrom, dateTo],
    queryFn: () => listLoads({ q, statuses: statusList, awaiting_paperwork: awaitingOnly, customer_id: customerId, driver_id: driverId, date_from: dateFrom, date_to: dateTo }),
  })
  const { data: loads = [], isLoading } = loadsQ

  // Click-to-sort on the list columns (default: newest pickup first).
  const [sort, setSort] = useState<SortState>({ key: 'pickup', dir: 'desc' })
  const sorted = useMemo(() => {
    const val = (l: Load): unknown => {
      switch (sort.key) {
        case 'load_number': return l.load_number
        case 'customer': return l.customer_name
        case 'pickup': return l.pickup_time ? new Date(l.pickup_time).getTime() : null
        case 'delivery': return l.delivery_time ? new Date(l.delivery_time).getTime() : null
        case 'driver': return l.driver_name
        case 'rate': return Number(l.rate)
        case 'rpm': return l.rate_per_mile
        case 'status': return l.status
        default: return null
      }
    }
    const dir = sort.dir === 'asc' ? 1 : -1
    // blanks/nulls stay last in BOTH directions (reversing would surface them)
    return [...loads].sort((a, b) => {
      const av = val(a), bv = val(b)
      const aNil = av == null || av === ''
      const bNil = bv == null || bv === ''
      if (aNil && bNil) return 0
      if (aNil) return 1
      if (bNil) return -1
      return dir * compareValues(av, bv)
    })
  }, [loads, sort])

  return (
    <div className="space-y-4">
    <MissingPodsBanner />
    <Card title="Loads" actions={<Button onClick={() => navigate('/dispatch')}>+ New Load</Button>}>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        {ALL_STATUSES.map((s) => {
          const on = statuses.has(s)
          return (
            <button
              key={s}
              onClick={() => toggleStatus(s)}
              className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium capitalize transition-colors ${
                on ? 'border-brand bg-brand text-white' : 'border-line text-muted hover:bg-surface-2 hover:text-body'
              }`}
              title={on ? 'Hide these loads' : 'Show these loads'}
            >
              <span className={`h-1.5 w-1.5 rounded-full ${on ? 'bg-white' : 'bg-current'}`} />
              {s.replace('_', ' ')}
            </button>
          )
        })}
        {statuses.size > 0 && (
          <button onClick={() => setStatuses(new Set())} className="px-2 py-1.5 text-sm text-muted hover:text-body" title="Show all statuses">
            Show all
          </button>
        )}
        <span className="mx-1 h-5 w-px self-center bg-line" />
        <button
          onClick={() => setAwaitingOnly((v) => !v)}
          className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium transition-colors ${
            awaitingOnly ? 'border-amber-500 bg-amber-500 text-white' : 'border-line text-muted hover:bg-surface-2 hover:text-body'
          }`}
          title="Show only loads awaiting final paperwork"
        >
          📄 Awaiting paperwork
        </button>
      </div>
      <div className="mb-4 flex flex-wrap gap-3">
        <Input placeholder="Search load #, broker #, address…" value={q} onChange={(e) => setQ(e.target.value)} className="w-full sm:w-64" />
        <Select value={customerId} onChange={(e) => setCustomerId(e.target.value)} className="w-full sm:w-56">
          <option value="">All customers</option>
          {customers.map((c) => (
            <option key={c.id} value={c.id}>
              {c.company_name}
            </option>
          ))}
        </Select>
        <Select value={driverId} onChange={(e) => setDriverId(e.target.value)} className="w-full sm:w-48">
          <option value="">All drivers</option>
          {drivers.map((d) => (
            <option key={d.id} value={d.id}>
              {d.full_name}
            </option>
          ))}
        </Select>
        <div className="flex items-center gap-2">
          <Input type="date" title="Pickup from" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} className="!w-40" />
          <span className="text-muted">–</span>
          <Input type="date" title="Pickup to" value={dateTo} onChange={(e) => setDateTo(e.target.value)} className="!w-40" />
        </div>
      </div>
      <div className="mb-3 flex flex-wrap items-center gap-2 text-sm">
        {views.map((v) => (
          <span key={v.name} className="inline-flex items-center gap-1 rounded-full border border-line px-2.5 py-1">
            <button type="button" className="font-medium text-brand hover:underline" title="Apply this saved view"
              onClick={() => applyView(v)}>
              {v.name}
            </button>
            <button type="button" className="text-muted hover:text-red-600" title="Delete saved view"
              onClick={() => persistViews(views.filter((x) => x.name !== v.name))}>
              ×
            </button>
          </span>
        ))}
        {savingView ? (
          <form className="inline-flex items-center gap-1" onSubmit={(e) => { e.preventDefault(); saveCurrentView() }}>
            <Input autoFocus placeholder="View name" value={viewName} onChange={(e) => setViewName(e.target.value)} className="!w-36 !py-1 text-xs" />
            <Button type="submit" className="!py-1 text-xs" disabled={!viewName.trim()}>Save</Button>
            <button type="button" className="text-xs text-muted hover:text-body" onClick={() => setSavingView(false)}>cancel</button>
          </form>
        ) : (
          <button type="button" className="text-xs font-medium text-muted hover:text-body" title="Save the current filters as a one-click view"
            onClick={() => setSavingView(true)}>
            + Save view
          </button>
        )}
        <span className="mx-1 h-5 w-px self-center bg-line" />
        <div className="relative">
          <button type="button" className="text-xs font-medium text-muted hover:text-body" onClick={() => setColsOpen((v) => !v)} aria-expanded={colsOpen} aria-haspopup="true">
            ⚙ Columns
          </button>
          {colsOpen && (
            <div className="absolute z-20 mt-1 w-40 rounded-lg border border-line bg-surface p-2 shadow-lg">
              {HIDEABLE.map((c) => (
                <label key={c.key} className="flex cursor-pointer items-center gap-2 py-0.5 text-sm">
                  <input type="checkbox" checked={show(c.key)} onChange={() => toggleCol(c.key)} /> {c.label}
                </label>
              ))}
            </div>
          )}
        </div>
      </div>

      {isLoading ? (
        <p className="py-8 text-center text-muted">Loading…</p>
      ) : loadsQ.isError ? (
        <LoadError error={loadsQ.error} onRetry={() => loadsQ.refetch()} />
      ) : loads.length === 0 ? (
        <div className="py-8 text-center text-muted">
          {q || customerId || driverId || dateFrom || dateTo || awaitingOnly || statuses.size > 0 ? (
            <>No loads match these filters — try <button type="button" className="font-medium text-brand hover:underline" onClick={() => { setQ(''); setStatuses(new Set()); setAwaitingOnly(false); setCustomerId(''); setDriverId(''); setDateFrom(''); setDateTo('') }}>clearing them</button>.</>
          ) : (
            <>No loads yet. Book the first one from <Link to="/dispatch" className="font-medium text-brand hover:underline">Dispatch</Link> — drop the rate confirmation PDF there and the form fills itself.</>
          )}
        </div>
      ) : (
        <Table
          headers={[
            { label: 'Load #', key: 'load_number' },
            ...(show('customer') ? [{ label: 'Customer', key: 'customer' }] : []),
            ...(show('pickup') ? [{ label: 'Pickup', key: 'pickup' }] : []),
            ...(show('delivery') ? [{ label: 'Delivery', key: 'delivery' }] : []),
            ...(show('driver') ? [{ label: 'Driver', key: 'driver' }] : []),
            ...(show('rate') ? [{ label: 'Rate', key: 'rate' }] : []),
            ...(show('rpm') ? [{ label: 'RPM', key: 'rpm' }] : []),
            { label: 'Status', key: 'status' },
            '',
          ]}
          sort={sort}
          onSort={(k) => setSort((p) => toggleSort(p, k))}
        >
          {sorted.map((load) => (
                <tr key={load.id} className="cursor-pointer hover:bg-surface-2" onClick={() => navigate(`/loads/${load.id}`)}>
                  <td className="px-3 py-3 font-medium text-brand">
                    <Link to={`/loads/${load.id}`} onClick={(e) => e.stopPropagation()}>
                      {load.load_number}
                    </Link>
                    {load.reference_number && <div className="text-xs font-normal text-muted">{load.reference_number}</div>}
                  </td>
                  {show('customer') && <td className="px-3 py-3">{load.customer_name}</td>}
                  {show('pickup') && (
                    <td className="px-3 py-3">
                      <div className="max-w-45 truncate">{load.pickup_address || '—'}</div>
                      <div className="text-xs text-muted">{formatDateTime(load.pickup_time)}</div>
                    </td>
                  )}
                  {show('delivery') && (
                    <td className="px-3 py-3">
                      <div className="max-w-45 truncate">{load.delivery_address || '—'}</div>
                      <div className="text-xs text-muted">{formatDateTime(load.delivery_time)}</div>
                    </td>
                  )}
                  {show('driver') && <td className="px-3 py-3" onClick={(e) => e.stopPropagation()}>
                    {['pending', 'assigned'].includes(load.status) ? (
                      <select
                        className="max-w-36 rounded border border-line bg-transparent px-1 py-0.5 text-sm"
                        value={load.driver_id ?? ''}
                        disabled={swapDriver.isPending}
                        onChange={(e) => swapDriver.mutate({ id: load.id, driverId: e.target.value })}
                        title="Swap driver without opening the load"
                      >
                        <option value="">—</option>
                        {drivers.filter((d) => d.status === 'active' || d.id === load.driver_id).map((d) => (
                          <option key={d.id} value={d.id}>{d.full_name}</option>
                        ))}
                      </select>
                    ) : (load.driver_name ?? '—')}
                  </td>}
                  {show('rate') && <td className="px-3 py-3">{money(load.rate)}</td>}
                  {show('rpm') && <td className="px-3 py-3">{load.rate_per_mile != null ? `$${load.rate_per_mile.toFixed(2)}` : '—'}</td>}
                  <td className="px-3 py-3">
                    <div className="flex flex-col items-start gap-1">
                      <Badge status={load.status} />
                      {(() => {
                        const r = etaByLoad.get(load.id)
                        if (!r || load.status !== 'in_transit') return null
                        const tone = r.risk === 'late' ? 'bg-rose-500/15 text-rose-600 dark:text-rose-300'
                          : r.risk === 'hos_short' || r.risk === 'tight' ? 'bg-amber-500/15 text-amber-600 dark:text-amber-300'
                          : 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-300'
                        const label = r.risk === 'late' ? 'ETA past appt' : r.risk === 'hos_short' ? 'HOS short' : r.risk === 'tight' ? 'Tight' : 'On track'
                        return (
                          <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold ${tone}`}
                            title={`ETA ${new Date(r.eta).toLocaleString()} vs appt ${new Date(r.appointment).toLocaleString()} — ${r.miles_to_go} mi to go, ${r.slack_h}h slack (estimate)`}>
                            ⏱ {label}
                          </span>
                        )
                      })()}
                      {load.awaiting_paperwork && (
                        <span className="inline-flex items-center gap-1 rounded-full bg-amber-500/15 px-2 py-0.5 text-xs font-semibold text-amber-600 dark:text-amber-300" title="Booked — final paperwork not received yet">
                          📄 Awaiting paperwork
                        </span>
                      )}
                      {(() => {
                        const idx = LOAD_STATUSES.indexOf(load.status)
                        if (idx < 0 || idx >= LOAD_STATUSES.indexOf('completed')) return null
                        const next = LOAD_STATUSES[idx + 1]
                        return (
                          <button
                            type="button"
                            disabled={advance.isPending}
                            onClick={(e) => { e.stopPropagation(); advance.mutate({ id: load.id, status: next }) }}
                            className="rounded border border-line px-1.5 py-0.5 text-xs text-muted hover:text-body"
                            title={`Advance to ${next.replace('_', ' ')} without opening the load`}
                          >→ {next.replace('_', ' ')}</button>
                        )
                      })()}
                      {rowErr[load.id] && <span className="max-w-44 text-xs text-red-600">{rowErr[load.id]}</span>}
                    </div>
                  </td>
                  <td className="px-3 py-3">
                    <button
                      type="button"
                      title="Book this lane again — opens Dispatch prefilled (dates, driver, and truck cleared)"
                      onClick={(e) => { e.stopPropagation(); navigate('/dispatch', { state: { clone: load } }) }}
                      className="rounded-lg border border-line px-2 py-1 text-xs text-muted hover:text-body"
                    >⧉ Clone</button>
                  </td>
            </tr>
          ))}
        </Table>
      )}
    </Card>
    </div>
  )
}

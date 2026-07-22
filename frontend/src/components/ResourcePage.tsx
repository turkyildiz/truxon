/**
 * Generic list + create/edit-modal page used by Customers, Drivers, Trucks,
 * Trailers, Maintenance, and Users. Pages supply data functions (list /
 * create / update) and field configs; this handles fetching, searching,
 * and saving.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react'
import { useSearchParams } from 'react-router-dom'
import { errorMessage } from '../supabase'
import DocsNotes from './DocsNotes'
import { Button, Card, compareValues, Field, Input, LoadError, Modal, Select, type SortState, Table, Textarea, toggleSort } from './ui'

export interface FieldDef {
  name: string
  label: string
  type?: 'text' | 'number' | 'date' | 'datetime-local' | 'select' | 'textarea' | 'checkbox' | 'password' | 'email'
  options?: { value: string; label: string }[]
  required?: boolean
  step?: string
  full?: boolean
  createOnly?: boolean
  /** Hide the field unless the current form state says it applies
   * (e.g. a rate that only matters when its checkbox is on). */
  showIf?: (form: Record<string, unknown>) => boolean
}

export interface ColumnDef<T> {
  header: string
  render: (item: T) => ReactNode
  /** When set (with `sortValue`), the header becomes click-to-sort. */
  sortKey?: string
  /** Comparable value for sorting (dates as epoch millis, numbers as numbers). */
  sortValue?: (item: T) => unknown
}

interface Props<T extends { id: number | string }> {
  title: string
  queryKey: string
  list: (q: string) => Promise<T[]>
  create: (payload: Record<string, unknown>) => Promise<unknown>
  update: (id: T['id'], payload: Record<string, unknown>) => Promise<unknown>
  columns: ColumnDef<T>[]
  fields: FieldDef[]
  toForm: (item: T) => Record<string, unknown>
  defaults: Record<string, unknown>
  searchable?: boolean
  addLabel?: string
  /** When set, each row gets a "Docs" action opening the entity-generic
   * documents + notes panel (spec: every major record carries both). */
  docs?: { entityType: string; docTypes: string[]; label: (item: T) => string }
  /** Externally-supplied form values (e.g. AI-extracted from a PDF): when
   * set, the create modal opens prefilled; the page then clears it via
   * onPrefillConsumed. */
  prefill?: Record<string, unknown> | null
  onPrefillConsumed?: () => void
  /** Load dynamic select options when opening create/edit. */
  fieldOptionsLoader?: (item: T | null) => Promise<Record<string, { value: string; label: string }[]>>
  /** When set, the edit modal shows a Delete button. `fn` should reject with a
   * human-readable message when the delete isn't allowed (the server enforces
   * the real rule). `confirm` builds the confirmation prompt. */
  remove?: { fn: (id: T['id']) => Promise<unknown>; confirm?: (item: T) => string }
  /** Initial column sort, for pages whose columns declare sortKey/sortValue. */
  defaultSort?: SortState
}

export default function ResourcePage<T extends { id: number | string }>({
  title,
  queryKey,
  list,
  create,
  update,
  columns,
  fields,
  toForm,
  defaults,
  searchable = true,
  addLabel,
  docs,
  prefill,
  onPrefillConsumed,
  fieldOptionsLoader,
  remove,
  defaultSort,
}: Props<T>) {
  const qc = useQueryClient()
  const [params] = useSearchParams()
  const urlQ = params.get('q') ?? ''
  const [q, setQ] = useState(urlQ)
  const [editing, setEditing] = useState<T | null>(null)
  const [creating, setCreating] = useState(false)
  const [docsFor, setDocsFor] = useState<T | null>(null)
  const [form, setForm] = useState<Record<string, unknown>>({})
  const [error, setError] = useState('')
  const [dynamicOptions, setDynamicOptions] = useState<Record<string, { value: string; label: string }[]>>({})

  // Global search deep-links here with ?q=…; pick it up even when the page
  // is already mounted.
  useEffect(() => {
    if (urlQ) setQ(urlQ)
  }, [urlQ])

  useEffect(() => {
    if (prefill) {
      setForm({ ...defaults, ...prefill })
      setEditing(null)
      setCreating(true)
      setError('')
      onPrefillConsumed?.()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- fire per prefill object only
  }, [prefill])

  const listQ = useQuery({
    queryKey: [queryKey, q],
    queryFn: () => list(q),
  })
  const { data: items = [], isLoading } = listQ

  // Click-to-sort on columns that declare sortKey/sortValue.
  const [sort, setSort] = useState<SortState | null>(defaultSort ?? null)
  const sorted = useMemo(() => {
    const col = sort ? columns.find((c) => c.sortKey === sort.key) : undefined
    const val = col?.sortValue
    if (!sort || !val) return items
    const dir = sort.dir === 'asc' ? 1 : -1
    // blanks/nulls stay last in BOTH directions (reversing would surface them)
    return [...items].sort((a, b) => {
      const av = val(a), bv = val(b)
      const aNil = av == null || av === ''
      const bNil = bv == null || bv === ''
      if (aNil && bNil) return 0
      if (aNil) return 1
      if (bNil) return -1
      return dir * compareValues(av, bv)
    })
  }, [items, sort, columns])

  const save = useMutation({
    mutationFn: (payload: Record<string, unknown>) => {
      // Empty strings for optional fields become null so Postgres accepts them.
      const cleaned = Object.fromEntries(
        Object.entries(payload).map(([k, v]) => [k, v === '' ? null : v]),
      )
      return editing ? update(editing.id, cleaned) : create(cleaned)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [queryKey] })
      close()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  const del = useMutation({
    mutationFn: (id: T['id']) => remove!.fn(id),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [queryKey] })
      close()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  function onDelete() {
    if (!editing || !remove) return
    const msg = remove.confirm?.(editing) ?? 'Delete this record permanently?'
    if (window.confirm(msg)) del.mutate(editing.id)
  }

  async function loadOptions(item: T | null) {
    if (!fieldOptionsLoader) {
      setDynamicOptions({})
      return
    }
    try {
      setDynamicOptions(await fieldOptionsLoader(item))
    } catch {
      setDynamicOptions({})
    }
  }

  function openCreate() {
    setForm({ ...defaults })
    setCreating(true)
    setError('')
    void loadOptions(null)
  }

  function openEdit(item: T) {
    setForm(toForm(item))
    setEditing(item)
    setError('')
    void loadOptions(item)
  }

  function close() {
    setEditing(null)
    setCreating(false)
    setError('')
    setDynamicOptions({})
  }

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    const payload = { ...form }
    if (editing) for (const f of fields) if (f.createOnly) delete payload[f.name]
    save.mutate(payload)
  }

  const visibleFields = fields.filter((f) => (!editing || !f.createOnly) && (f.showIf?.(form) ?? true))

  return (
    <Card
      title={title}
      actions={
        <div className="flex items-center gap-3">
          {searchable && <Input placeholder="Search…" value={q} onChange={(e) => setQ(e.target.value)} className="w-44 sm:w-64" />}
          <Button onClick={openCreate}>{addLabel ?? '+ Add'}</Button>
        </div>
      }
    >
      {isLoading ? (
        <p className="py-8 text-center text-muted">Loading…</p>
      ) : listQ.isError ? (
        <LoadError error={listQ.error} onRetry={() => listQ.refetch()} />
      ) : items.length === 0 ? (
        <p className="py-8 text-center text-muted">No records yet.</p>
      ) : (
        <Table
          headers={[...columns.map((c) => (c.sortKey && c.sortValue ? { label: c.header, key: c.sortKey } : c.header)), '']}
          sort={sort ?? undefined}
          onSort={(k) => setSort((p) => toggleSort(p, k))}
        >
          {sorted.map((item) => (
            <tr key={item.id} className="hover:bg-surface-2">
              {columns.map((c, i) => (
                <td key={i} className="px-3 py-3">
                  {c.render(item)}
                </td>
              ))}
              <td className="px-3 py-3 text-right whitespace-nowrap">
                {docs && (
                  <button onClick={() => setDocsFor(item)} className="mr-3 text-sm font-medium text-brand hover:underline">
                    Docs
                  </button>
                )}
                <button onClick={() => openEdit(item)} className="text-sm font-medium text-brand hover:underline">
                  Edit
                </button>
              </td>
            </tr>
          ))}
        </Table>
      )}

      {docs && (
        <Modal title={`Documents & Notes — ${docsFor ? docs.label(docsFor) : ''}`} open={!!docsFor} onClose={() => setDocsFor(null)}>
          {docsFor && <DocsNotes entityType={docs.entityType} entityId={docsFor.id} docTypes={docs.docTypes} className="space-y-4" />}
        </Modal>
      )}

      <Modal title={editing ? `Edit ${title.replace(/s$/, '')}` : `New ${title.replace(/s$/, '')}`} open={creating || !!editing} onClose={close}>
        <form onSubmit={onSubmit}>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            {visibleFields.map((f) => (
              <Field key={f.name} label={f.label} className={f.full ? 'sm:col-span-2' : ''}>
                {f.type === 'select' ? (
                  <Select value={String(form[f.name] ?? '')} onChange={(e) => setForm({ ...form, [f.name]: e.target.value })} required={f.required}>
                    {!f.required && <option value="">—</option>}
                    {(dynamicOptions[f.name] ?? f.options)?.map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </Select>
                ) : f.type === 'textarea' ? (
                  <Textarea value={String(form[f.name] ?? '')} onChange={(e) => setForm({ ...form, [f.name]: e.target.value })} />
                ) : f.type === 'checkbox' ? (
                  <input
                    type="checkbox"
                    checked={!!form[f.name]}
                    onChange={(e) => setForm({ ...form, [f.name]: e.target.checked })}
                    className="mt-2 h-5 w-5"
                  />
                ) : (
                  <Input
                    type={f.type ?? 'text'}
                    step={f.step}
                    required={f.required}
                    value={String(form[f.name] ?? '')}
                    onChange={(e) => setForm({ ...form, [f.name]: e.target.value })}
                  />
                )}
              </Field>
            ))}
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
          <div className="mt-5 flex items-center justify-between gap-3">
            <div>
              {editing && remove && (
                <Button type="button" variant="danger" onClick={onDelete} disabled={del.isPending}>
                  {del.isPending ? 'Deleting…' : 'Delete'}
                </Button>
              )}
            </div>
            <div className="flex gap-3">
              <Button type="button" variant="secondary" onClick={close}>
                Cancel
              </Button>
              <Button type="submit" disabled={save.isPending}>
                {save.isPending ? 'Saving…' : 'Save'}
              </Button>
            </div>
          </div>
        </form>
      </Modal>
    </Card>
  )
}

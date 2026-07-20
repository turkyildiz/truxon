import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button, Card, Field, Input, LoadError, PageHeader, Select } from '../components/ui'
import { searchDocuments, downloadDocumentById, type DocSearchMatch } from '../data'

const ENTITY_LABEL: Record<string, string> = {
  customer: 'Customer', load: 'Load', truck: 'Truck', trailer: 'Trailer', driver: 'Driver',
}

/** Link to the source record when a route exists for it, else a plain label. */
function EntityLink({ m }: { m: DocSearchMatch }) {
  const label = `${ENTITY_LABEL[m.entity_type] ?? m.entity_type} #${m.entity_id}`
  if (m.entity_type === 'load') return <Link to={`/loads/${m.entity_id}`} className="text-blue-600 hover:underline dark:text-blue-400">{label}</Link>
  if (m.entity_type === 'customer') return <Link to="/customers" className="text-blue-600 hover:underline dark:text-blue-400">{label}</Link>
  return <span className="text-muted">{label}</span>
}

export default function DocSearch() {
  const [q, setQ] = useState('')
  const [entity, setEntity] = useState('')
  const [results, setResults] = useState<DocSearchMatch[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const [downloading, setDownloading] = useState<number | null>(null)

  async function run(e: React.FormEvent) {
    e.preventDefault()
    if (q.trim().length < 2 || busy) return
    setBusy(true); setError(null); setResults(null)
    try {
      setResults(await searchDocuments(q.trim(), entity || undefined))
    } catch (err) {
      setError(err)
    } finally {
      setBusy(false)
    }
  }

  async function open(id: number) {
    setDownloading(id)
    try { await downloadDocumentById(id) } catch (err) { setError(err) } finally { setDownloading(null) }
  }

  return (
    <div className="space-y-4">
      <PageHeader title="Document Search" subtitle="Search the meaning of every uploaded document — rate cons, PODs, BOLs, work orders, contracts." />

      <Card>
        <form onSubmit={run} className="flex flex-wrap items-end gap-3">
          <Field label="Search" className="min-w-[18rem] flex-1">
            <Input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="e.g. detention terms, lumper fee, reefer 34°, TWIC required…"
              autoFocus
            />
          </Field>
          <Field label="Limit to" className="w-44">
            <Select value={entity} onChange={(e) => setEntity(e.target.value)}>
              <option value="">All documents</option>
              <option value="customer">Customers</option>
              <option value="load">Loads</option>
              <option value="truck">Trucks</option>
              <option value="trailer">Trailers</option>
              <option value="driver">Drivers</option>
            </Select>
          </Field>
          <Button type="submit" disabled={busy || q.trim().length < 2}>
            {busy ? 'Searching…' : 'Search'}
          </Button>
        </form>
        <p className="mt-2 text-xs text-muted">
          Semantic search runs on the NAS (local embeddings) — results usually land in a few seconds.
        </p>
      </Card>

      {error ? <LoadError error={error} /> : null}

      {results && !error && (
        results.length === 0 ? (
          <Card><p className="text-muted">No matching documents.</p></Card>
        ) : (
          <div className="space-y-3">
            {results.map((m, i) => (
              <Card key={`${m.document_id}-${i}`}>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="truncate font-semibold text-body">{m.filename}</span>
                      {m.doc_type && <span className="rounded-full bg-slate-500/15 px-2 py-0.5 text-xs font-medium text-slate-600 dark:text-slate-300">{m.doc_type}</span>}
                      <EntityLink m={m} />
                    </div>
                    <p className="mt-2 line-clamp-3 whitespace-pre-wrap text-sm text-muted">{m.content}</p>
                  </div>
                  <div className="flex shrink-0 flex-col items-end gap-2">
                    <span className="rounded-full bg-emerald-500/15 px-2 py-0.5 text-xs font-semibold text-emerald-600 dark:text-emerald-300">
                      {Math.round(m.similarity * 100)}% match
                    </span>
                    <Button variant="secondary" onClick={() => open(m.document_id)} disabled={downloading === m.document_id}>
                      {downloading === m.document_id ? 'Opening…' : 'Open'}
                    </Button>
                  </div>
                </div>
              </Card>
            ))}
          </div>
        )
      )}
    </div>
  )
}

import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button, Card, Field, Input, LoadError, PageHeader, Select } from '../components/ui'
import { searchDocuments, downloadDocumentById, downloadTeamDriveFileById, similarDocuments, type DocSearchMatch, type SimilarDoc } from '../data'

const ENTITY_LABEL: Record<string, string> = {
  customer: 'Customer', load: 'Load', truck: 'Truck', trailer: 'Trailer', driver: 'Driver',
}

/** Link to the source record when a route exists for it, else a plain label. */
function EntityLink({ m }: { m: DocSearchMatch }) {
  if (m.entity_type === 'team_drive') return <Link to="/team-drive" className="text-blue-600 hover:underline dark:text-blue-400">Team Drive</Link>
  const label = `${ENTITY_LABEL[m.entity_type] ?? m.entity_type} #${m.entity_id}`
  if (m.entity_type === 'load') return <Link to={`/loads/${m.entity_id}`} className="text-blue-600 hover:underline dark:text-blue-400">{label}</Link>
  if (m.entity_type === 'customer') return <Link to="/customers" className="text-blue-600 hover:underline dark:text-blue-400">{label}</Link>
  return <span className="text-muted">{label}</span>
}

export default function DocSearch() {
  const [q, setQ] = useState('')
  const [entity, setEntity] = useState('')
  const [docType, setDocType] = useState('')
  const [results, setResults] = useState<DocSearchMatch[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const [downloading, setDownloading] = useState<number | null>(null)
  const [similar, setSimilar] = useState<{ key: number; items: SimilarDoc[] | 'loading' } | null>(null)

  async function moreLikeThis(m: DocSearchMatch, key: number) {
    if (m.document_id == null) return
    if (similar?.key === key) { setSimilar(null); return }  // toggle off
    setSimilar({ key, items: 'loading' })
    try { setSimilar({ key, items: await similarDocuments(m.document_id) }) }
    catch (err) { setSimilar(null); setError(err) }
  }

  async function run(e: React.FormEvent) {
    e.preventDefault()
    if (q.trim().length < 2 || busy) return
    setBusy(true); setError(null); setResults(null)
    try {
      setResults(await searchDocuments(q.trim(), entity || undefined))
      // doc-type narrows client-side — matches already carry their label
    } catch (err) {
      setError(err)
    } finally {
      setBusy(false)
    }
  }

  async function open(m: DocSearchMatch, key: number) {
    setDownloading(key)
    try {
      if (m.drive_file_id != null) await downloadTeamDriveFileById(m.drive_file_id)
      else if (m.document_id != null) await downloadDocumentById(m.document_id)
    } catch (err) { setError(err) } finally { setDownloading(null) }
  }

  const shown = (results ?? []).filter((m) => !docType || m.doc_type === docType)
  const typesInResults = [...new Set((results ?? []).map((m) => m.doc_type).filter(Boolean))] as string[]

  return (
    <div className="space-y-4">
      <PageHeader title="Document Search" subtitle="Search the meaning of every uploaded document — rate cons, PODs, BOLs, work orders, contracts, and Team Drive files." />

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
              <option value="team_drive">Team Drive</option>
            </Select>
          </Field>
          {typesInResults.length > 1 && (
            <Field label="Type">
              <Select value={docType} onChange={(e) => setDocType(e.target.value)}>
                <option value="">All types</option>
                {typesInResults.map((t) => <option key={t} value={t}>{t}</option>)}
              </Select>
            </Field>
          )}
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
        shown.length === 0 ? (
          <Card><p className="text-muted">{results.length === 0 ? 'No matching documents.' : `No ${docType} documents in these results — clear the type filter.`}</p></Card>
        ) : (
          <div className="space-y-3">
            {docType && <p className="text-xs text-muted">{shown.length} of {results.length} results are {docType}.</p>}
            {shown.map((m, i) => (
              <Card key={`${m.document_id ?? 'd'}-${m.drive_file_id ?? 'f'}-${i}`}>
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
                    <Button variant="secondary" onClick={() => open(m, i)} disabled={downloading === i}>
                      {downloading === i ? 'Opening…' : 'Open'}
                    </Button>
                    {m.document_id != null && (
                      <Button variant="secondary" onClick={() => moreLikeThis(m, i)}>
                        {similar?.key === i ? (similar.items === 'loading' ? 'Finding…' : 'Hide similar') : 'More like this'}
                      </Button>
                    )}
                  </div>
                </div>
                {similar?.key === i && similar.items !== 'loading' && (
                  <div className="mt-3 border-t border-border pt-2">
                    {similar.items.length === 0 ? (
                      <p className="text-xs text-muted">No similar documents indexed yet.</p>
                    ) : similar.items.map((s) => (
                      <button
                        key={s.document_id}
                        onClick={() => downloadDocumentById(s.document_id).catch((err) => setError(err))}
                        className="flex w-full items-center justify-between gap-2 rounded px-2 py-1 text-left text-sm hover:bg-slate-500/10"
                      >
                        <span className="min-w-0 truncate">{s.filename}
                          {s.doc_type && <span className="ml-2 text-xs text-muted">{s.doc_type}</span>}
                          <span className="ml-2 text-xs text-muted">{s.entity}</span>
                        </span>
                        <span className="shrink-0 text-xs text-muted">{Math.round(s.similarity * 100)}%</span>
                      </button>
                    ))}
                  </div>
                )}
              </Card>
            ))}
          </div>
        )
      )}
    </div>
  )
}

/**
 * Documents + Notes & Activity panels for any record type (load, driver,
 * truck, trailer, customer, maintenance) — the documents table, storage
 * paths, and activity log are all entity-generic; callers pick the
 * doc-type choices that make sense for their record.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useRef, useState } from 'react'
import { addNote, attachPodFromArchive, downloadDocument, downloadEntityDocsZip, listActivity, listDocuments, podArchiveCandidate, uploadDocument } from '../data'
import { errorMessage } from '../supabase'
import type { DocumentMeta } from '../types'
import { Button, Card, formatDateTime, Input, LoadError, Select } from './ui'

/** For a load with no POD on file yet: if a matching file sits in the PODs
 *  archive, offer a one-click copy into this load's Documents. */
function PodArchiveAttach({ loadId, hasPod }: { loadId: number; hasPod: boolean }) {
  const qc = useQueryClient()
  const [err, setErr] = useState('')
  const candQ = useQuery({
    queryKey: ['pod-candidate', loadId],
    queryFn: () => podArchiveCandidate(loadId),
    enabled: !hasPod,
    staleTime: 60_000,
  })
  const attach = useMutation({
    mutationFn: () => attachPodFromArchive(loadId),
    onSuccess: () => {
      setErr('')
      qc.invalidateQueries({ queryKey: ['docs', 'load', String(loadId)] })
      qc.invalidateQueries({ queryKey: ['pod-candidate', loadId] })
      qc.invalidateQueries({ queryKey: ['missing-pods'] })
    },
    onError: (e) => setErr(errorMessage(e)),
  })
  if (hasPod || !candQ.data) return null
  return (
    <div className="mb-3 rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-amber-700 dark:text-amber-300">
          📄 Found a matching POD in the archive: <span className="font-medium">{candQ.data.filename}</span>
        </span>
        <Button onClick={() => attach.mutate()} disabled={attach.isPending}>
          {attach.isPending ? 'Attaching…' : 'Attach as POD'}
        </Button>
      </div>
      {err && <p className="mt-1 text-xs text-red-600">{err}</p>}
    </div>
  )
}

interface Props {
  entityType: string
  entityId: number | string
  docTypes: string[]
  /** Layout wrapper class — side-by-side on detail pages, stacked in modals. */
  className?: string
}

export default function DocsNotes({ entityType, entityId, docTypes, className = 'grid grid-cols-1 gap-4 lg:grid-cols-2' }: Props) {
  const qc = useQueryClient()
  const [docError, setDocError] = useState('')
  const [noteError, setNoteError] = useState('')
  const [note, setNote] = useState('')
  const [docType, setDocType] = useState('')
  const fileRef = useRef<HTMLInputElement>(null)

  const docsQ = useQuery({ queryKey: ['docs', entityType, String(entityId)], queryFn: () => listDocuments(entityType, entityId) })
  const activityQ = useQuery({ queryKey: ['activity', entityType, String(entityId)], queryFn: () => listActivity(entityType, entityId) })
  const docs = docsQ.data ?? []
  const activity = activityQ.data ?? []

  const upload = useMutation({
    mutationFn: (file: File) => uploadDocument(entityType, entityId, file, docType),
    onSuccess: () => {
      if (fileRef.current) fileRef.current.value = ''
      setDocError('')
      qc.invalidateQueries({ queryKey: ['docs', entityType, String(entityId)] })
    },
    onError: (err) => setDocError(errorMessage(err)),
  })

  const noteMutation = useMutation({
    mutationFn: () => addNote(entityType, entityId, note),
    onSuccess: () => {
      setNote('')
      setNoteError('')
      qc.invalidateQueries({ queryKey: ['activity', entityType, String(entityId)] })
    },
    onError: (err) => setNoteError(errorMessage(err)),
  })

  function download(d: DocumentMeta) {
    downloadDocument(d).catch((err) => setDocError(errorMessage(err)))
  }

  // R9 #111: everything on this entity as one zip, foldered by doc type.
  const zipAll = useMutation({
    mutationFn: () => downloadEntityDocsZip(entityType, entityId, `${entityType}-${entityId}`),
    onError: (err) => setDocError(errorMessage(err)),
  })

  // A load counts as having a POD if any evidence doc is on file (case-insensitive
  // to match the detector: pod/bol/receipt/scale).
  const hasPod = docs.some((d) => ['pod', 'bol', 'receipt', 'scale'].includes((d.doc_type ?? '').toLowerCase()))

  return (
    <div className={className}>
      <Card title="Documents">
        {entityType === 'load' && <PodArchiveAttach loadId={Number(entityId)} hasPod={hasPod} />}
        <div className="mb-3 flex flex-wrap gap-2">
          <Select value={docType} onChange={(e) => setDocType(e.target.value)} className="!w-44">
            <option value="">Type…</option>
            {docTypes.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </Select>
          <input
            ref={fileRef}
            type="file"
            onChange={(e) => e.target.files?.[0] && upload.mutate(e.target.files[0])}
            className="text-sm file:mr-3 file:rounded-lg file:border-0 file:bg-navy-700 file:px-4 file:py-2.5 file:text-sm file:font-medium file:text-white hover:file:bg-navy-800"
          />
        </div>
        {docs.length > 1 && (
          <div className="mb-2">
            <Button variant="secondary" onClick={() => zipAll.mutate()} disabled={zipAll.isPending}>
              {zipAll.isPending ? 'Zipping…' : `Download all (${docs.length}) as zip`}
            </Button>
          </div>
        )}
        {upload.isPending && <p className="mb-2 text-sm text-muted">Uploading…</p>}
        {docError && <p className="mb-2 text-sm text-red-600">{docError}</p>}
        {docsQ.isError ? (
          <LoadError error={docsQ.error} onRetry={() => docsQ.refetch()} />
        ) : docs.length === 0 ? (
          <p className="text-sm text-muted">No documents uploaded.</p>
        ) : (
          <ul className="divide-y divide-line text-sm">
            {docs.map((d) => (
              <li key={d.id} className="flex items-center justify-between py-2">
                <div>
                  <button onClick={() => download(d)} className="font-medium text-brand hover:underline">
                    {d.filename}
                  </button>
                  <span className="ml-2 text-xs text-muted">
                    {d.doc_type && `${d.doc_type} · `}
                    {(d.size_bytes / 1024).toFixed(0)} KB
                  </span>
                </div>
                <span className="text-xs text-muted">{formatDateTime(d.uploaded_at)}</span>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card title="Notes & Activity">
        <div className="mb-3 flex gap-2">
          <Input
            placeholder="Add a note…"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && note && noteMutation.mutate()}
          />
          <Button onClick={() => noteMutation.mutate()} disabled={!note || noteMutation.isPending}>
            Add
          </Button>
        </div>
        {noteError && <p className="mb-2 text-sm text-red-600">{noteError}</p>}
        {activityQ.isError ? (
          <LoadError error={activityQ.error} onRetry={() => activityQ.refetch()} />
        ) : (
          <ul className="max-h-80 space-y-2 overflow-y-auto text-sm">
            {activity.length === 0 && <li className="text-muted">No notes or activity yet.</li>}
            {activity.map((a) => (
              <li key={a.id} className={`rounded-lg p-2.5 ${a.action === 'note' ? 'bg-amber-500/10' : 'bg-surface-2'}`}>
                <div className="flex justify-between text-xs text-muted">
                  <span className="font-semibold">
                    {a.action === 'note' ? '📝 note' : a.action.replace('_', ' ')} — {a.user_name ?? 'system'}
                  </span>
                  <span>{formatDateTime(a.created_at)}</span>
                </div>
                {a.detail && <div className="mt-1">{a.detail}</div>}
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  )
}

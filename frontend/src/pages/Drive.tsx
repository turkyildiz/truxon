/** Dropbox-like file area, shared by Personal Drive (private to each user)
 * and Team Drive (shared across staff). RLS on drive_files + the storage
 * buckets does the real access control; this is the UI over it. */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useRef, useState } from 'react'
import { useAuth } from '../auth'
import {
  deleteDriveFile,
  downloadDriveFile,
  listDriveFiles,
  listDriveFolders,
  uploadDriveFile,
  type DriveFile,
} from '../data'
import { errorMessage } from '../supabase'
import { Card, formatDateTime, Input, LoadError, Select } from '../components/ui'

function fileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export default function Drive({ drive }: { drive: 'personal' | 'team' }) {
  const qc = useQueryClient()
  const { user } = useAuth()
  const fileRef = useRef<HTMLInputElement>(null)
  const [folder, setFolder] = useState('')
  const [newFolder, setNewFolder] = useState('')
  const [q, setQ] = useState('')
  const [error, setError] = useState('')

  const isTeam = drive === 'team'
  const title = isTeam ? 'Team Drive' : 'Personal Drive'
  const subtitle = isTeam
    ? 'Shared with everyone on the team. Anyone can add files; you can remove your own (admins can remove any).'
    : 'Private to you. No one else — not even an admin — can see these files.'

  const filesQ = useQuery({ queryKey: ['drive', drive], queryFn: () => listDriveFiles(drive) })
  const foldersQ = useQuery({ queryKey: ['drive-folders', drive], queryFn: () => listDriveFolders(drive) })
  const files = filesQ.data ?? []

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['drive', drive] })
    qc.invalidateQueries({ queryKey: ['drive-folders', drive] })
  }

  const upload = useMutation({
    mutationFn: (file: File) => uploadDriveFile(drive, file, newFolder || folder),
    onSuccess: () => {
      if (fileRef.current) fileRef.current.value = ''
      setError('')
      invalidate()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  const remove = useMutation({
    mutationFn: (f: DriveFile) => deleteDriveFile(f),
    onSuccess: () => {
      setError('')
      invalidate()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  function download(f: DriveFile) {
    downloadDriveFile(f).catch((err) => setError(errorMessage(err)))
  }

  const visible = useMemo(() => {
    return files.filter(
      (f) => (folder === '' || f.folder === folder) && (!q || f.filename.toLowerCase().includes(q.toLowerCase())),
    )
  }, [files, folder, q])

  const canDelete = (f: DriveFile) => !isTeam || f.owner_id === user?.id || user?.role === 'admin'

  return (
    <Card
      title={title}
      actions={
        <div className="flex items-center gap-3">
          <Input placeholder="Search files…" value={q} onChange={(e) => setQ(e.target.value)} className="w-40 sm:w-56" />
        </div>
      }
    >
      <p className="mb-4 text-sm text-slate-500">{subtitle}</p>

      <div className="mb-4 flex flex-wrap items-end gap-3 rounded-xl bg-slate-50 p-3">
        <label className="text-sm">
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-slate-500">Folder (optional)</span>
          <Input placeholder="e.g. Contracts" value={newFolder} onChange={(e) => setNewFolder(e.target.value)} className="w-44" />
        </label>
        <label className="cursor-pointer rounded-lg bg-navy-700 px-4 py-2.5 text-sm font-medium text-white hover:bg-navy-800">
          {upload.isPending ? 'Uploading…' : '⬆ Upload file'}
          <input ref={fileRef} type="file" className="hidden" onChange={(e) => e.target.files?.[0] && upload.mutate(e.target.files[0])} />
        </label>
        <span className="text-xs text-slate-400">Up to 100 MB per file.</span>
      </div>

      {error && <p className="mb-3 text-sm text-red-600">{error}</p>}

      {(foldersQ.data?.length ?? 0) > 0 && (
        <div className="mb-3">
          <Select value={folder} onChange={(e) => setFolder(e.target.value)} className="w-56">
            <option value="">All folders</option>
            {foldersQ.data!.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </Select>
        </div>
      )}

      {filesQ.isError ? (
        <LoadError error={filesQ.error} onRetry={() => filesQ.refetch()} />
      ) : filesQ.isLoading ? (
        <p className="py-8 text-center text-slate-500">Loading…</p>
      ) : visible.length === 0 ? (
        <p className="py-8 text-center text-slate-500">No files yet. Upload one above.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-slate-200 text-left">
                {['Name', 'Folder', ...(isTeam ? ['Added by'] : []), 'Size', 'Uploaded', ''].map((h) => (
                  <th key={h} className="px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-slate-500">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {visible.map((f) => (
                <tr key={f.id} className="hover:bg-slate-50">
                  <td className="px-3 py-3">
                    <button onClick={() => download(f)} className="font-medium text-navy-600 hover:underline">
                      {f.filename}
                    </button>
                  </td>
                  <td className="px-3 py-3 text-slate-500">{f.folder || '—'}</td>
                  {isTeam && <td className="px-3 py-3 text-slate-500">{f.owner_name ?? '—'}</td>}
                  <td className="px-3 py-3 text-slate-500">{fileSize(f.size_bytes)}</td>
                  <td className="px-3 py-3 text-slate-500">{formatDateTime(f.uploaded_at)}</td>
                  <td className="px-3 py-3 text-right whitespace-nowrap">
                    <button onClick={() => download(f)} className="mr-3 text-sm font-medium text-navy-600 hover:underline">
                      Download
                    </button>
                    {canDelete(f) && (
                      <button
                        onClick={() => window.confirm(`Delete "${f.filename}"? This can't be undone.`) && remove.mutate(f)}
                        className="text-sm font-medium text-red-600 hover:underline"
                      >
                        Delete
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}

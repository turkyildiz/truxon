/** Dropbox-like file area for Personal Drive (private) and Team Drive (shared).
 * Real nested folders (metadata: parent + is_folder), grid/list views,
 * drag-drop upload, previews via signed URLs, rename/move/delete. RLS on
 * drive_files + the storage buckets is the real access control. */
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useRef, useState } from 'react'
import {
  createDriveFolder,
  deleteDriveItems,
  downloadDriveItem,
  driveSignedUrl,
  listDriveFolderPaths,
  listDriveItems,
  moveDriveItems,
  renameDriveItem,
  searchDriveItems,
  uploadDriveFile,
  type DriveItem,
} from '../data'
import { errorMessage } from '../supabase'
import { Button, formatDateTime, Input, LoadError, Modal } from '../components/ui'

function fileSize(bytes: number): string {
  if (!bytes) return '—'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`
}

const fullPathOf = (i: DriveItem) => (i.parent === '' ? i.filename : `${i.parent}/${i.filename}`)
const isImage = (i: DriveItem) => i.content_type.startsWith('image/')
const isPdf = (i: DriveItem) => i.content_type === 'application/pdf'

/** Emoji + tile colour by type — a big step up from the old icon-less table. */
function icon(i: DriveItem): { emoji: string; bg: string } {
  if (i.is_folder) return { emoji: '📁', bg: 'bg-amber-400/15' }
  const ct = i.content_type
  const ext = i.filename.split('.').pop()?.toLowerCase() ?? ''
  if (ct.startsWith('image/')) return { emoji: '🖼️', bg: 'bg-purple-400/15' }
  if (ct === 'application/pdf' || ext === 'pdf') return { emoji: '📕', bg: 'bg-red-400/15' }
  if (['doc', 'docx'].includes(ext)) return { emoji: '📘', bg: 'bg-blue-400/15' }
  if (['xls', 'xlsx', 'csv'].includes(ext)) return { emoji: '📗', bg: 'bg-green-400/15' }
  if (['ppt', 'pptx'].includes(ext)) return { emoji: '📙', bg: 'bg-orange-400/15' }
  if (['zip', 'rar', '7z', 'gz'].includes(ext)) return { emoji: '🗜️', bg: 'bg-yellow-400/15' }
  if (ct.startsWith('video/')) return { emoji: '🎬', bg: 'bg-pink-400/15' }
  if (ct.startsWith('audio/')) return { emoji: '🎵', bg: 'bg-teal-400/15' }
  if (['txt', 'md', 'json', 'log'].includes(ext)) return { emoji: '📄', bg: 'bg-slate-400/15' }
  return { emoji: '📄', bg: 'bg-slate-400/15' }
}

/** Signed-URL image thumbnail (falls back to the type icon). */
function Thumb({ item, size }: { item: DriveItem; size: number }) {
  const q = useQuery({
    queryKey: ['drive-thumb', item.id],
    queryFn: () => driveSignedUrl(item.drive, item.storage_path!, undefined),
    enabled: isImage(item) && !!item.storage_path,
    staleTime: 50 * 60 * 1000,
  })
  const ic = icon(item)
  if (isImage(item) && q.data) {
    return <img src={q.data} alt="" className="rounded-lg object-cover" style={{ width: size, height: size }} />
  }
  return (
    <div className={`flex items-center justify-center rounded-lg ${ic.bg}`} style={{ width: size, height: size, fontSize: size * 0.5 }}>
      {ic.emoji}
    </div>
  )
}

export default function Drive({ drive }: { drive: 'personal' | 'team' }) {
  const qc = useQueryClient()
  const isTeam = drive === 'team'
  const fileRef = useRef<HTMLInputElement>(null)

  const [path, setPath] = useState('')
  const [view, setView] = useState<'grid' | 'list'>('grid')
  const [search, setSearch] = useState('')
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const [sort, setSort] = useState<{ key: 'name' | 'modified' | 'size'; dir: 'asc' | 'desc' }>({ key: 'name', dir: 'asc' })
  const [preview, setPreview] = useState<DriveItem | null>(null)
  const [renaming, setRenaming] = useState<DriveItem | null>(null)
  const [renameVal, setRenameVal] = useState('')
  const [moving, setMoving] = useState<number[] | null>(null)
  const [newFolder, setNewFolder] = useState<string | null>(null)
  const [dragOver, setDragOver] = useState(false)
  const [uploading, setUploading] = useState<{ done: number; total: number } | null>(null)
  const [error, setError] = useState('')

  const searching = search.trim().length > 0
  const itemsQ = useQuery({ queryKey: ['drive', drive, path], queryFn: () => listDriveItems(drive, path), enabled: !searching })
  const searchQ = useQuery({ queryKey: ['drive-search', drive, search.trim()], queryFn: () => searchDriveItems(drive, search.trim()), enabled: searching })
  const activeQ = searching ? searchQ : itemsQ

  const clearSel = () => setSelected(new Set())
  const invalidate = () => qc.invalidateQueries({ queryKey: ['drive', drive] })

  const items = useMemo(() => {
    const arr = (activeQ.data ?? []).slice()
    arr.sort((a, b) => {
      if (a.is_folder !== b.is_folder) return a.is_folder ? -1 : 1
      let r = 0
      if (sort.key === 'name') r = a.filename.localeCompare(b.filename)
      else if (sort.key === 'size') r = a.size_bytes - b.size_bytes
      else r = a.uploaded_at.localeCompare(b.uploaded_at)
      return sort.dir === 'asc' ? r : -r
    })
    return arr
  }, [activeQ.data, sort])

  function go(p: string) {
    setPath(p)
    setSearch('')
    clearSel()
  }
  function open(i: DriveItem) {
    if (i.is_folder) go(fullPathOf(i))
    else if (isImage(i) || isPdf(i)) setPreview(i)
    else downloadDriveItem(i).catch((e) => setError(errorMessage(e)))
  }
  function toggle(id: number) {
    setSelected((s) => {
      const n = new Set(s)
      if (n.has(id)) n.delete(id)
      else n.add(id)
      return n
    })
  }

  async function doUpload(files: FileList | File[]) {
    const arr = Array.from(files)
    if (!arr.length) return
    setError('')
    setUploading({ done: 0, total: arr.length })
    for (let i = 0; i < arr.length; i++) {
      try {
        await uploadDriveFile(drive, arr[i], path)
      } catch (e) {
        setError(errorMessage(e))
      }
      setUploading({ done: i + 1, total: arr.length })
    }
    setUploading(null)
    if (fileRef.current) fileRef.current.value = ''
    invalidate()
  }

  async function run(fn: () => Promise<void>) {
    try {
      await fn()
      setError('')
    } catch (e) {
      setError(errorMessage(e))
    } finally {
      invalidate()
    }
  }

  const selItems = items.filter((i) => selected.has(i.id))
  const crumbs = path === '' ? [] : path.split('/')

  return (
    <div
      className="space-y-3"
      onDragOver={(e) => {
        e.preventDefault()
        if (!dragOver) setDragOver(true)
      }}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target) setDragOver(false)
      }}
      onDrop={(e) => {
        e.preventDefault()
        setDragOver(false)
        if (e.dataTransfer.files?.length) doUpload(e.dataTransfer.files)
      }}
    >
      {/* header */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold text-body">{isTeam ? 'Team Drive' : 'Personal Drive'}</h1>
          <p className="text-xs text-muted">
            {isTeam ? 'Shared with everyone. Anyone can add and organize; you remove your own (admins remove any).' : 'Private to you — no one else, not even an admin, can see these files.'}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Input placeholder="Search this drive…" value={search} onChange={(e) => setSearch(e.target.value)} className="w-44 sm:w-56" />
          <Button variant="secondary" onClick={() => setNewFolder('')}>＋ Folder</Button>
          <Button onClick={() => fileRef.current?.click()}>⬆ Upload</Button>
          <input ref={fileRef} type="file" multiple className="hidden" onChange={(e) => e.target.files && doUpload(e.target.files)} />
          <div className="flex overflow-hidden rounded-lg border border-line">
            <button onClick={() => setView('grid')} className={`px-2.5 py-1.5 text-sm ${view === 'grid' ? 'bg-surface-2 text-body' : 'text-muted'}`} title="Grid">▦</button>
            <button onClick={() => setView('list')} className={`px-2.5 py-1.5 text-sm ${view === 'list' ? 'bg-surface-2 text-body' : 'text-muted'}`} title="List">☰</button>
          </div>
        </div>
      </div>

      {/* breadcrumbs */}
      {!searching && (
        <div className="flex flex-wrap items-center gap-1 text-sm">
          <button onClick={() => go('')} className={`rounded px-1.5 py-0.5 hover:bg-surface-2 ${path === '' ? 'font-semibold text-body' : 'text-brand'}`}>
            {isTeam ? '🗂️ Team' : '📁 Home'}
          </button>
          {crumbs.map((c, i) => {
            const to = crumbs.slice(0, i + 1).join('/')
            const last = i === crumbs.length - 1
            return (
              <span key={to} className="flex items-center gap-1">
                <span className="text-muted">/</span>
                <button onClick={() => go(to)} className={`rounded px-1.5 py-0.5 hover:bg-surface-2 ${last ? 'font-semibold text-body' : 'text-brand'}`}>{c}</button>
              </span>
            )
          })}
        </div>
      )}

      {error && <p className="rounded-lg bg-red-500/10 p-3 text-sm text-red-600 dark:text-red-300">{error}</p>}
      {uploading && (
        <p className="rounded-lg bg-blue-500/10 p-3 text-sm text-blue-700 dark:text-blue-300">Uploading {uploading.done}/{uploading.total}…</p>
      )}

      {/* selection toolbar */}
      {selected.size > 0 && (
        <div className="flex flex-wrap items-center gap-2 rounded-lg bg-surface-2 px-3 py-2 text-sm">
          <span className="font-medium">{selected.size} selected</span>
          <div className="ml-auto flex flex-wrap gap-2">
            <Button variant="secondary" onClick={() => selItems.forEach((i) => !i.is_folder && downloadDriveItem(i).catch((e) => setError(errorMessage(e))))}>Download</Button>
            <Button variant="secondary" onClick={() => setMoving([...selected])}>Move</Button>
            {selected.size === 1 && (
              <Button
                variant="secondary"
                onClick={() => {
                  const it = selItems[0]
                  setRenaming(it)
                  setRenameVal(it.filename)
                }}
              >
                Rename
              </Button>
            )}
            <Button
              variant="danger"
              onClick={() => {
                if (window.confirm(`Delete ${selected.size} item(s)? Folders remove everything inside. This can't be undone.`)) {
                  run(() => deleteDriveItems(drive, [...selected]))
                  clearSel()
                }
              }}
            >
              Delete
            </Button>
            <Button variant="secondary" onClick={clearSel}>✕</Button>
          </div>
        </div>
      )}

      {/* content */}
      {activeQ.isError ? (
        <LoadError error={activeQ.error} onRetry={() => activeQ.refetch()} />
      ) : activeQ.isLoading ? (
        <p className="py-10 text-center text-muted">Loading…</p>
      ) : items.length === 0 ? (
        <div className="rounded-xl border-2 border-dashed border-line py-16 text-center">
          <p className="text-muted">{searching ? 'No matches.' : 'This folder is empty.'}</p>
          {!searching && <p className="mt-1 text-sm text-muted">Drag files here, or use Upload.</p>}
        </div>
      ) : view === 'grid' ? (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
          {items.map((i) => {
            const sel = selected.has(i.id)
            return (
              <div
                key={i.id}
                onClick={() => toggle(i.id)}
                onDoubleClick={() => open(i)}
                className={`group relative cursor-pointer rounded-xl border p-3 transition-colors ${sel ? 'border-brand bg-brand/5' : 'border-line hover:bg-surface-2'}`}
                title={i.filename}
              >
                <input
                  type="checkbox"
                  checked={sel}
                  onChange={() => toggle(i.id)}
                  onClick={(e) => e.stopPropagation()}
                  className={`absolute left-2 top-2 h-4 w-4 ${sel ? '' : 'opacity-0 group-hover:opacity-100'}`}
                />
                <div className="flex justify-center py-2">
                  <Thumb item={i} size={72} />
                </div>
                <div className="truncate text-center text-sm font-medium text-body">{i.filename}</div>
                <div className="truncate text-center text-xs text-muted">
                  {i.is_folder ? 'Folder' : fileSize(i.size_bytes)}
                  {searching && i.parent ? ` · in ${i.parent}` : ''}
                </div>
              </div>
            )
          })}
        </div>
      ) : (
        <div className="overflow-x-auto rounded-xl border border-line">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-line bg-surface-2 text-left">
                <th className="w-8 px-3 py-2.5">
                  <input
                    type="checkbox"
                    checked={items.length > 0 && selected.size === items.length}
                    onChange={(e) => setSelected(e.target.checked ? new Set(items.map((i) => i.id)) : new Set())}
                    className="h-4 w-4"
                  />
                </th>
                {([['name', 'Name'], ['modified', 'Modified'], ['size', 'Size']] as const).map(([key, label]) => (
                  <th key={key} className="px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-muted">
                    <button
                      onClick={() => setSort((s) => ({ key, dir: s.key === key && s.dir === 'asc' ? 'desc' : 'asc' }))}
                      className="inline-flex items-center gap-1 hover:text-body"
                    >
                      {label}
                      {sort.key === key && <span>{sort.dir === 'asc' ? '↑' : '↓'}</span>}
                    </button>
                  </th>
                ))}
                {isTeam && <th className="px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-muted">Added by</th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {items.map((i) => {
                const sel = selected.has(i.id)
                const ic = icon(i)
                return (
                  <tr key={i.id} className={`cursor-pointer ${sel ? 'bg-brand/5' : 'hover:bg-surface-2'}`} onClick={() => toggle(i.id)} onDoubleClick={() => open(i)}>
                    <td className="px-3 py-2.5" onClick={(e) => e.stopPropagation()}>
                      <input type="checkbox" checked={sel} onChange={() => toggle(i.id)} className="h-4 w-4" />
                    </td>
                    <td className="px-3 py-2.5">
                      <button
                        onClick={(e) => {
                          e.stopPropagation()
                          open(i)
                        }}
                        className="flex items-center gap-2 text-left font-medium text-body hover:text-brand"
                      >
                        <span className={`flex h-7 w-7 items-center justify-center rounded ${ic.bg}`}>{ic.emoji}</span>
                        <span className="truncate">{i.filename}</span>
                        {searching && i.parent && <span className="text-xs text-muted">· {i.parent}</span>}
                      </button>
                    </td>
                    <td className="px-3 py-2.5 text-muted whitespace-nowrap">{formatDateTime(i.uploaded_at)}</td>
                    <td className="px-3 py-2.5 text-muted whitespace-nowrap">{i.is_folder ? '—' : fileSize(i.size_bytes)}</td>
                    {isTeam && <td className="px-3 py-2.5 text-muted">{i.owner_name ?? '—'}</td>}
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* drag overlay */}
      {dragOver && (
        <div className="pointer-events-none fixed inset-0 z-40 flex items-center justify-center bg-brand/10 backdrop-blur-sm">
          <div className="rounded-2xl border-2 border-dashed border-brand bg-surface px-8 py-6 text-lg font-semibold text-brand">Drop to upload to {path === '' ? 'this drive' : path}</div>
        </div>
      )}

      {/* preview */}
      <Modal title={preview?.filename ?? ''} open={!!preview} onClose={() => setPreview(null)}>
        {preview && <PreviewBody item={preview} onDownload={() => downloadDriveItem(preview).catch((e) => setError(errorMessage(e)))} />}
      </Modal>

      {/* new folder */}
      <Modal title="New folder" open={newFolder !== null} onClose={() => setNewFolder(null)}>
        <form
          onSubmit={(e) => {
            e.preventDefault()
            const name = (newFolder ?? '').trim()
            if (name) run(() => createDriveFolder(drive, path, name))
            setNewFolder(null)
          }}
        >
          <Input autoFocus placeholder="Folder name" value={newFolder ?? ''} onChange={(e) => setNewFolder(e.target.value)} />
          <div className="mt-4 flex justify-end gap-2">
            <Button type="button" variant="secondary" onClick={() => setNewFolder(null)}>Cancel</Button>
            <Button type="submit">Create</Button>
          </div>
        </form>
      </Modal>

      {/* rename */}
      <Modal title="Rename" open={!!renaming} onClose={() => setRenaming(null)}>
        <form
          onSubmit={(e) => {
            e.preventDefault()
            const it = renaming!
            const name = renameVal.trim()
            if (name && name !== it.filename) run(() => renameDriveItem(it.id, name))
            setRenaming(null)
            clearSel()
          }}
        >
          <Input autoFocus value={renameVal} onChange={(e) => setRenameVal(e.target.value)} />
          <div className="mt-4 flex justify-end gap-2">
            <Button type="button" variant="secondary" onClick={() => setRenaming(null)}>Cancel</Button>
            <Button type="submit">Save</Button>
          </div>
        </form>
      </Modal>

      {/* move */}
      <MoveModal
        drive={drive}
        open={moving !== null}
        movingIds={moving ?? []}
        currentParent={path}
        onClose={() => setMoving(null)}
        onMove={(dest) => {
          const ids = moving ?? []
          run(() => moveDriveItems(ids, dest))
          setMoving(null)
          clearSel()
        }}
      />
    </div>
  )
}

function PreviewBody({ item, onDownload }: { item: DriveItem; onDownload: () => void }) {
  const q = useQuery({ queryKey: ['drive-preview', item.id], queryFn: () => driveSignedUrl(item.drive, item.storage_path!, undefined), enabled: !!item.storage_path })
  return (
    <div className="space-y-3">
      {q.isLoading ? (
        <p className="py-10 text-center text-muted">Loading preview…</p>
      ) : q.isError || !q.data ? (
        <p className="py-10 text-center text-muted">Preview unavailable.</p>
      ) : isImage(item) ? (
        <img src={q.data} alt={item.filename} className="mx-auto max-h-[70vh] rounded-lg" />
      ) : isPdf(item) ? (
        <iframe src={q.data} title={item.filename} className="h-[70vh] w-full rounded-lg border border-line" />
      ) : (
        <p className="py-10 text-center text-muted">No inline preview for this file type.</p>
      )}
      <div className="flex justify-end">
        <Button onClick={onDownload}>⬇ Download</Button>
      </div>
    </div>
  )
}

function MoveModal({
  drive,
  open,
  movingIds,
  currentParent,
  onClose,
  onMove,
}: {
  drive: 'personal' | 'team'
  open: boolean
  movingIds: number[]
  currentParent: string
  onClose: () => void
  onMove: (dest: string) => void
}) {
  const foldersQ = useQuery({ queryKey: ['drive-folder-paths', drive], queryFn: () => listDriveFolderPaths(drive), enabled: open })
  // Can't move an item into itself or its own subtree.
  const movingSet = new Set(movingIds)
  const dests = (foldersQ.data ?? []).filter((f) => !movingSet.has(f.id))
  return (
    <Modal title="Move to…" open={open} onClose={onClose}>
      <div className="max-h-[50vh] space-y-1 overflow-y-auto">
        <button
          disabled={currentParent === ''}
          onClick={() => onMove('')}
          className="block w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-surface-2 disabled:opacity-40"
        >
          📁 {drive === 'team' ? 'Team' : 'Home'} (root)
        </button>
        {dests.map((f) => (
          <button
            key={f.id}
            disabled={f.path === currentParent}
            onClick={() => onMove(f.path)}
            className="block w-full truncate rounded-lg px-3 py-2 text-left text-sm hover:bg-surface-2 disabled:opacity-40"
          >
            📁 {f.path}
          </button>
        ))}
        {dests.length === 0 && <p className="px-3 py-6 text-center text-sm text-muted">No other folders yet — create one first.</p>}
      </div>
    </Modal>
  )
}

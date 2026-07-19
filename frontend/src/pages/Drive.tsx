/** Dropbox-like file area for Personal Drive (private) and Team Drive (shared).
 * Nested folders (metadata: parent + is_folder), grid/list views, drag-drop
 * upload of files AND folders, in-app drag-to-move, previews and public share
 * links via signed URLs, rename/move/delete. RLS on drive_files + the storage
 * buckets is the real access control. */
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useRef, useState } from 'react'
import {
  createDriveFolder,
  createDriveShare,
  deleteDriveItems,
  downloadDriveItem,
  driveShareUrl,
  driveSignedUrl,
  ensureDrivePath,
  listDriveFolderPaths,
  listDriveItems,
  listDriveShares,
  moveDriveItems,
  renameDriveItem,
  revokeDriveShare,
  searchDriveItems,
  uploadDriveFile,
  type DriveItem,
} from '../data'
import { errorMessage } from '../supabase'
import { Button, formatDateTime, Input, LoadError, Modal } from '../components/ui'

type DriveName = 'personal' | 'team'
interface UploadEntry {
  file: File
  rel: string
}

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
const isFileDrag = (e: React.DragEvent) => Array.from(e.dataTransfer.types).includes('Files')

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

// ---- folder-drop traversal (webkitGetAsEntry) ----
/* eslint-disable @typescript-eslint/no-explicit-any -- FileSystemEntry APIs are untyped */
async function readEntry(entry: any, prefix: string, out: UploadEntry[]): Promise<void> {
  if (entry.isFile) {
    const file: File = await new Promise((res, rej) => entry.file(res, rej))
    out.push({ file, rel: prefix + entry.name })
  } else if (entry.isDirectory) {
    const reader = entry.createReader()
    for (;;) {
      const batch: any[] = await new Promise((res, rej) => reader.readEntries(res, rej))
      if (!batch.length) break
      for (const child of batch) await readEntry(child, `${prefix}${entry.name}/`, out)
    }
  }
}
function entriesFromDrop(dt: DataTransfer): any[] | null {
  if (!dt.items?.length) return null
  const entries: any[] = []
  for (let i = 0; i < dt.items.length; i++) {
    const it = dt.items[i] as any
    if (it.kind !== 'file' || !it.webkitGetAsEntry) continue
    const en = it.webkitGetAsEntry()
    if (en) entries.push(en)
  }
  return entries.length ? entries : null
}
/* eslint-enable @typescript-eslint/no-explicit-any */

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

export default function Drive({ drive }: { drive: DriveName }) {
  const qc = useQueryClient()
  const isTeam = drive === 'team'
  const fileRef = useRef<HTMLInputElement>(null)
  const folderRef = useRef<HTMLInputElement>(null)
  const dragRef = useRef<number[] | null>(null)

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
  const [sharing, setSharing] = useState<DriveItem | null>(null)
  const [dragOver, setDragOver] = useState(false)
  const [dropTarget, setDropTarget] = useState<string | null>(null)
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

  // ---- uploads ----
  async function doUpload(files: FileList | File[], basePath = path) {
    const arr = Array.from(files)
    if (!arr.length) return
    setError('')
    setUploading({ done: 0, total: arr.length })
    for (let i = 0; i < arr.length; i++) {
      try {
        await uploadDriveFile(drive, arr[i], basePath)
      } catch (e) {
        setError(errorMessage(e))
      }
      setUploading({ done: i + 1, total: arr.length })
    }
    setUploading(null)
    if (fileRef.current) fileRef.current.value = ''
    invalidate()
  }
  async function doUploadEntries(entries: UploadEntry[], basePath = path) {
    if (!entries.length) return
    setError('')
    setUploading({ done: 0, total: entries.length })
    const ensured = new Set<string>()
    for (let i = 0; i < entries.length; i++) {
      const { file, rel } = entries[i]
      const parts = rel.split('/')
      parts.pop()
      const relDir = parts.join('/')
      const parent = relDir ? (basePath ? `${basePath}/${relDir}` : relDir) : basePath
      try {
        if (relDir && !ensured.has(parent)) {
          await ensureDrivePath(drive, parent)
          ensured.add(parent)
        }
        await uploadDriveFile(drive, file, parent)
      } catch (e) {
        setError(errorMessage(e))
      }
      setUploading({ done: i + 1, total: entries.length })
    }
    setUploading(null)
    if (folderRef.current) folderRef.current.value = ''
    invalidate()
  }
  function handleExternalDrop(e: React.DragEvent, base: string) {
    const entries = entriesFromDrop(e.dataTransfer)
    if (entries) readAllThenUpload(entries, base)
    else if (e.dataTransfer.files?.length) doUpload(e.dataTransfer.files, base)
  }
  async function readAllThenUpload(entries: unknown[], base: string) {
    const out: UploadEntry[] = []
    for (const en of entries) await readEntry(en, '', out)
    if (out.length) doUploadEntries(out, base)
  }

  // ---- drag to move ----
  function onItemDragStart(e: React.DragEvent, item: DriveItem) {
    const ids = selected.has(item.id) && selected.size > 0 ? [...selected] : [item.id]
    dragRef.current = ids
    e.dataTransfer.effectAllowed = 'move'
    e.dataTransfer.setData('application/x-trux', ids.join(','))
  }
  function onDropInto(e: React.DragEvent, dest: string, excludeId?: number) {
    e.preventDefault()
    e.stopPropagation()
    setDropTarget(null)
    setDragOver(false)
    if (isFileDrag(e)) {
      handleExternalDrop(e, dest)
      return
    }
    const ids = (dragRef.current ?? []).filter((id) => id !== excludeId)
    dragRef.current = null
    if (ids.length) run(() => moveDriveItems(ids, dest)).then(clearSel)
  }
  function targetProps(key: string, dest: string, excludeId?: number) {
    return {
      onDragOver: (e: React.DragEvent) => {
        if (isFileDrag(e) || dragRef.current) {
          e.preventDefault()
          e.stopPropagation()
          e.dataTransfer.dropEffect = isFileDrag(e) ? 'copy' : 'move'
          if (dropTarget !== key) setDropTarget(key)
        }
      },
      onDragLeave: () => setDropTarget((t) => (t === key ? null : t)),
      onDrop: (e: React.DragEvent) => onDropInto(e, dest, excludeId),
    }
  }

  const selItems = items.filter((i) => selected.has(i.id))
  const oneFile = selItems.length === 1 && !selItems[0].is_folder
  const crumbs = path === '' ? [] : path.split('/')

  return (
    <div
      className="space-y-3"
      onDragOver={(e) => {
        if (isFileDrag(e)) {
          e.preventDefault()
          if (!dragOver) setDragOver(true)
        }
      }}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target) setDragOver(false)
      }}
      onDrop={(e) => {
        e.preventDefault()
        setDragOver(false)
        if (isFileDrag(e)) handleExternalDrop(e, path)
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
          <Input placeholder="Search this drive…" value={search} onChange={(e) => setSearch(e.target.value)} className="w-40 sm:w-52" />
          <Button variant="secondary" onClick={() => setNewFolder('')} title="New folder">＋ Folder</Button>
          <Button onClick={() => fileRef.current?.click()} title="Upload files">⬆ Files</Button>
          <Button variant="secondary" onClick={() => folderRef.current?.click()} title="Upload a folder from your computer">⬆ Folder</Button>
          <input ref={fileRef} type="file" multiple className="hidden" onChange={(e) => e.target.files && doUpload(e.target.files)} />
          <input
            ref={folderRef}
            type="file"
            className="hidden"
            /* @ts-expect-error non-standard directory-upload attributes */
            webkitdirectory=""
            directory=""
            onChange={(e) => {
              const files = e.target.files
              if (files?.length) {
                const entries: UploadEntry[] = Array.from(files).map((f) => ({ file: f, rel: (f as File & { webkitRelativePath?: string }).webkitRelativePath || f.name }))
                doUploadEntries(entries)
              }
            }}
          />
          <div className="flex overflow-hidden rounded-lg border border-line">
            <button onClick={() => setView('grid')} className={`px-2.5 py-1.5 text-sm ${view === 'grid' ? 'bg-surface-2 text-body' : 'text-muted'}`} title="Grid">▦</button>
            <button onClick={() => setView('list')} className={`px-2.5 py-1.5 text-sm ${view === 'list' ? 'bg-surface-2 text-body' : 'text-muted'}`} title="List">☰</button>
          </div>
        </div>
      </div>

      {/* breadcrumbs (also move drop targets) */}
      {!searching && (
        <div className="flex flex-wrap items-center gap-1 text-sm">
          <button
            onClick={() => go('')}
            {...targetProps('croot', '')}
            className={`rounded px-1.5 py-0.5 ${dropTarget === 'croot' ? 'bg-brand/15 ring-1 ring-brand' : 'hover:bg-surface-2'} ${path === '' ? 'font-semibold text-body' : 'text-brand'}`}
          >
            {isTeam ? '🗂️ Team' : '📁 Home'}
          </button>
          {crumbs.map((c, i) => {
            const to = crumbs.slice(0, i + 1).join('/')
            const last = i === crumbs.length - 1
            return (
              <span key={to} className="flex items-center gap-1">
                <span className="text-muted">/</span>
                <button
                  onClick={() => go(to)}
                  {...targetProps(`c${to}`, to)}
                  className={`rounded px-1.5 py-0.5 ${dropTarget === `c${to}` ? 'bg-brand/15 ring-1 ring-brand' : 'hover:bg-surface-2'} ${last ? 'font-semibold text-body' : 'text-brand'}`}
                >
                  {c}
                </button>
              </span>
            )
          })}
        </div>
      )}

      {error && <p className="rounded-lg bg-red-500/10 p-3 text-sm text-red-600 dark:text-red-300">{error}</p>}
      {uploading && <p className="rounded-lg bg-blue-500/10 p-3 text-sm text-blue-700 dark:text-blue-300">Uploading {uploading.done}/{uploading.total}…</p>}

      {/* selection toolbar */}
      {selected.size > 0 && (
        <div className="flex flex-wrap items-center gap-2 rounded-lg bg-surface-2 px-3 py-2 text-sm">
          <span className="font-medium">{selected.size} selected</span>
          <div className="ml-auto flex flex-wrap gap-2">
            {oneFile && <Button variant="secondary" onClick={() => setSharing(selItems[0])}>Share</Button>}
            <Button variant="secondary" onClick={() => selItems.forEach((i) => !i.is_folder && downloadDriveItem(i).catch((e) => setError(errorMessage(e))))}>Download</Button>
            <Button variant="secondary" onClick={() => setMoving([...selected])}>Move</Button>
            {selected.size === 1 && (
              <Button
                variant="secondary"
                onClick={() => {
                  setRenaming(selItems[0])
                  setRenameVal(selItems[0].filename)
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
          {!searching && <p className="mt-1 text-sm text-muted">Drag files or folders here, or use Upload.</p>}
        </div>
      ) : view === 'grid' ? (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
          {items.map((i) => {
            const sel = selected.has(i.id)
            const isTarget = i.is_folder && dropTarget === `f${i.id}`
            return (
              <div
                key={i.id}
                draggable
                onDragStart={(e) => onItemDragStart(e, i)}
                onDragEnd={() => (dragRef.current = null)}
                onClick={() => toggle(i.id)}
                onDoubleClick={() => open(i)}
                {...(i.is_folder ? targetProps(`f${i.id}`, fullPathOf(i), i.id) : {})}
                className={`group relative cursor-pointer rounded-xl border p-3 transition-colors ${isTarget ? 'border-brand ring-2 ring-brand' : sel ? 'border-brand bg-brand/5' : 'border-line hover:bg-surface-2'}`}
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
                    <button onClick={() => setSort((s) => ({ key, dir: s.key === key && s.dir === 'asc' ? 'desc' : 'asc' }))} className="inline-flex items-center gap-1 hover:text-body">
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
                const isTarget = i.is_folder && dropTarget === `f${i.id}`
                return (
                  <tr
                    key={i.id}
                    draggable
                    onDragStart={(e) => onItemDragStart(e, i)}
                    onDragEnd={() => (dragRef.current = null)}
                    className={`cursor-pointer ${isTarget ? 'ring-2 ring-inset ring-brand' : sel ? 'bg-brand/5' : 'hover:bg-surface-2'}`}
                    onClick={() => toggle(i.id)}
                    onDoubleClick={() => open(i)}
                    {...(i.is_folder ? targetProps(`f${i.id}`, fullPathOf(i), i.id) : {})}
                  >
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

      {/* drag overlay (file upload only) */}
      {dragOver && (
        <div className="pointer-events-none fixed inset-0 z-40 flex items-center justify-center bg-brand/10 backdrop-blur-sm">
          <div className="rounded-2xl border-2 border-dashed border-brand bg-surface px-8 py-6 text-lg font-semibold text-brand">Drop to upload to {path === '' ? 'this drive' : path}</div>
        </div>
      )}

      {/* preview */}
      <Modal title={preview?.filename ?? ''} open={!!preview} onClose={() => setPreview(null)}>
        {preview && (
          <PreviewBody
            item={preview}
            onDownload={() => downloadDriveItem(preview).catch((e) => setError(errorMessage(e)))}
            onShare={() => {
              setSharing(preview)
              setPreview(null)
            }}
          />
        )}
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
          run(() => moveDriveItems(ids, dest)).then(clearSel)
          setMoving(null)
        }}
      />

      {/* share */}
      <ShareModal item={sharing} open={!!sharing} onClose={() => setSharing(null)} />
    </div>
  )
}

function PreviewBody({ item, onDownload, onShare }: { item: DriveItem; onDownload: () => void; onShare: () => void }) {
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
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onShare}>🔗 Share</Button>
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
  drive: DriveName
  open: boolean
  movingIds: number[]
  currentParent: string
  onClose: () => void
  onMove: (dest: string) => void
}) {
  const foldersQ = useQuery({ queryKey: ['drive-folder-paths', drive], queryFn: () => listDriveFolderPaths(drive), enabled: open })
  const movingSet = new Set(movingIds)
  const dests = (foldersQ.data ?? []).filter((f) => !movingSet.has(f.id))
  return (
    <Modal title="Move to…" open={open} onClose={onClose}>
      <div className="max-h-[50vh] space-y-1 overflow-y-auto">
        <button disabled={currentParent === ''} onClick={() => onMove('')} className="block w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-surface-2 disabled:opacity-40">
          📁 {drive === 'team' ? 'Team' : 'Home'} (root)
        </button>
        {dests.map((f) => (
          <button key={f.id} disabled={f.path === currentParent} onClick={() => onMove(f.path)} className="block w-full truncate rounded-lg px-3 py-2 text-left text-sm hover:bg-surface-2 disabled:opacity-40">
            📁 {f.path}
          </button>
        ))}
        {dests.length === 0 && <p className="px-3 py-6 text-center text-sm text-muted">No other folders yet — create one first.</p>}
      </div>
    </Modal>
  )
}

function ShareModal({ item, open, onClose }: { item: DriveItem | null; open: boolean; onClose: () => void }) {
  const qc = useQueryClient()
  const sharesQ = useQuery({ queryKey: ['drive-shares', item?.id], queryFn: () => listDriveShares(item!.id), enabled: open && !!item })
  const [busy, setBusy] = useState(false)
  const [copied, setCopied] = useState('')
  const [err, setErr] = useState('')

  async function create() {
    if (!item) return
    setBusy(true)
    setErr('')
    try {
      await createDriveShare(item.id)
      qc.invalidateQueries({ queryKey: ['drive-shares', item.id] })
    } catch (e) {
      setErr(errorMessage(e))
    } finally {
      setBusy(false)
    }
  }
  async function revoke(id: number) {
    await revokeDriveShare(id)
    qc.invalidateQueries({ queryKey: ['drive-shares', item?.id] })
  }
  function copy(url: string) {
    navigator.clipboard?.writeText(url)
    setCopied(url)
    setTimeout(() => setCopied(''), 1500)
  }
  const shares = sharesQ.data ?? []

  return (
    <Modal title={`Share "${item?.filename ?? ''}"`} open={open} onClose={onClose}>
      <p className="mb-3 text-sm text-muted">Anyone with a link below can download this file — no sign-in needed. Revoke a link any time to turn it off.</p>
      {err && <p className="mb-2 text-sm text-red-600">{err}</p>}
      {shares.length === 0 ? (
        <p className="py-2 text-sm text-muted">No links yet.</p>
      ) : (
        <ul className="space-y-2">
          {shares.map((s) => {
            const url = driveShareUrl(s.token)
            return (
              <li key={s.id} className="flex items-center gap-2 rounded-lg border border-line p-2">
                <input readOnly value={url} onFocus={(e) => e.currentTarget.select()} className="min-w-0 flex-1 truncate rounded bg-surface-2 px-2 py-1 text-xs" />
                <Button variant="secondary" onClick={() => copy(url)}>{copied === url ? 'Copied' : 'Copy'}</Button>
                <Button variant="danger" onClick={() => revoke(s.id)}>Revoke</Button>
              </li>
            )
          })}
        </ul>
      )}
      <div className="mt-4 flex justify-end">
        <Button disabled={busy} onClick={create}>{busy ? 'Creating…' : '＋ Create link'}</Button>
      </div>
    </Modal>
  )
}

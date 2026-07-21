// Document RAG — indexing + semantic search over Truxon's documents.
// The NAS extracts text + embeds it locally (nomic-embed-text); vectors live in
// pgvector here. The NAS holds no DB secrets — this function does storage access
// + the writes; the NAS only needs the public anon token + a local model.
//
// Modes (verify_jwt off; gated in-function):
//   targets  (cron anon)  → docs needing embedding + signed URLs (cursor paged)
//   upsert   (cron anon)  → store a doc's {content, embedding} chunks (blanks-ok)
//   search   (admin)      → cosine-similarity search from a query embedding
//   probe    (cron/admin) → indexing progress counts

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json, requireCron, withCors } from '../_shared/auth.ts'

function isCronBearer(req: Request): boolean {
  return requireCron(req)
}

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  const cron = isCronBearer(req)

  // ── probe: indexing progress ──
  if (body.mode === 'probe') {
    if (!cron) { const c = await getCaller(req); if (c instanceof Response) return c; if (c.role !== 'admin') return json({ error: 'Admin only' }, 403) }
    const total = (await svc.from('documents').select('id', { count: 'exact', head: true })).count ?? 0
    const indexed = (await svc.from('documents').select('id', { count: 'exact', head: true }).not('indexed_at', 'is', null)).count ?? 0
    const chunks = (await svc.from('document_embeddings').select('id', { count: 'exact', head: true })).count ?? 0
    const driveTotal = (await svc.from('drive_files').select('id', { count: 'exact', head: true }).eq('drive', 'team')).count ?? 0
    const driveIndexed = (await svc.from('drive_files').select('id', { count: 'exact', head: true }).eq('drive', 'team').not('indexed_at', 'is', null)).count ?? 0
    return json({ total, indexed, unindexed: total - indexed, chunks, drive_total: driveTotal, drive_indexed: driveIndexed })
  }

  // ── targets: docs needing embedding + signed URLs (NAS) ──
  if (body.mode === 'targets') {
    if (!cron) return json({ error: 'cron only' }, 403)
    const afterId = Number(body.after_id) || 0
    const limit = Math.min(Math.max(Number(body.limit) || 10, 1), 40)
    const { data: docs } = await svc.from('documents')
      .select('id, entity_type, entity_id, filename, content_type, storage_path')
      .is('indexed_at', null).gt('id', afterId).order('id', { ascending: true }).limit(limit)
    const targets: Array<Record<string, unknown>> = []
    let lastId = afterId
    for (const d of docs ?? []) {
      lastId = d.id as number
      const isPdf = /pdf/i.test(d.content_type) || /\.pdf$/i.test(d.filename)
      if (!isPdf) continue // only PDFs for now (images/other skipped)
      const { data: signed } = await svc.storage.from('documents').createSignedUrl(d.storage_path, 900)
      if (!signed?.signedUrl) continue
      targets.push({ document_id: d.id, entity_type: d.entity_type, entity_id: d.entity_id, filename: d.filename, url: signed.signedUrl })
    }
    return json({ targets, lastId, queried: (docs ?? []).length })
  }

  // ── upsert: store a doc's chunks (NAS) ──
  if (body.mode === 'upsert') {
    if (!cron) return json({ error: 'cron only' }, 403)
    const documentId = Number(body.document_id)
    if (!documentId) return json({ error: 'document_id required' }, 400)
    const { data: n, error } = await svc.rpc('upsert_doc_embeddings', {
      p_document_id: documentId,
      p_entity_type: String(body.entity_type ?? ''),
      p_entity_id: Number(body.entity_id) || 0,
      p_chunks: body.chunks ?? [],
    })
    if (error) return json({ error: error.message }, 500)
    return json({ chunks: Number(n) || 0 })
  }

  // ── search: cosine similarity from a query embedding ──
  if (body.mode === 'search') {
    if (!cron) { const c = await getCaller(req); if (c instanceof Response) return c; if (!['admin', 'dispatcher', 'accountant'].includes(c.role)) return json({ error: 'Not enough permissions' }, 403) }
    const emb = body.query_embedding
    if (!Array.isArray(emb) || emb.length === 0) return json({ error: 'query_embedding (number[]) required' }, 400)
    const { data, error } = await svc.rpc('match_document_embeddings', {
      p_embedding: JSON.stringify(emb),
      p_count: Number(body.count) || 12,
      p_entity_type: body.entity_type ?? null,
    })
    if (error) return json({ error: error.message }, 500)
    return json({ matches: data })
  }

  // ── drive_targets: Team Drive PDFs needing embedding + signed URLs (NAS) ──
  if (body.mode === 'drive_targets') {
    if (!cron) return json({ error: 'cron only' }, 403)
    const afterId = Number(body.after_id) || 0
    const limit = Math.min(Math.max(Number(body.limit) || 10, 1), 40)
    const { data: files } = await svc.from('drive_files')
      .select('id, filename, content_type, storage_path')
      .eq('drive', 'team')
      .is('indexed_at', null).gt('id', afterId).order('id', { ascending: true }).limit(limit)
    const targets: Array<Record<string, unknown>> = []
    let lastId = afterId
    for (const f of files ?? []) {
      lastId = f.id as number
      const isPdf = /pdf/i.test(f.content_type) || /\.pdf$/i.test(f.filename)
      if (!isPdf) continue
      const { data: signed } = await svc.storage.from('team').createSignedUrl(f.storage_path, 900)
      if (!signed?.signedUrl) continue
      targets.push({ drive_file_id: f.id, filename: f.filename, url: signed.signedUrl })
    }
    return json({ targets, lastId, queried: (files ?? []).length })
  }

  // ── drive_upsert: store a Team Drive file's chunks (NAS) ──
  if (body.mode === 'drive_upsert') {
    if (!cron) return json({ error: 'cron only' }, 403)
    const driveFileId = Number(body.drive_file_id)
    if (!driveFileId) return json({ error: 'drive_file_id required' }, 400)
    const { data: n, error } = await svc.rpc('upsert_drive_embeddings', {
      p_drive_file_id: driveFileId,
      p_chunks: body.chunks ?? [],
    })
    if (error) return json({ error: error.message }, 500)
    return json({ chunks: Number(n) || 0 })
  }

  // ── drive_owner: the admin uid — the storage-path prefix for bulk imports ──
  // (a uid grants no access by itself; every gate keys on verified JWTs)
  if (body.mode === 'drive_owner') {
    if (!cron) return json({ error: 'cron only' }, 403)
    const { data: admin } = await svc.from('profiles').select('id').eq('role', 'admin').limit(1).single()
    return json({ owner_uid: admin?.id ?? null })
  }

  // ── drive_register: create metadata rows for bulk-uploaded team files ──
  // Used by the Dropbox import (deploy/drive-import). Only registers objects
  // that actually exist in the private team bucket — the public-token gate
  // can't invent rows for bytes that aren't there. Idempotent by storage_path.
  if (body.mode === 'drive_register') {
    if (!cron) return json({ error: 'cron only' }, 403)
    const files = Array.isArray(body.files) ? body.files as Array<Record<string, unknown>> : []
    if (files.length === 0 || files.length > 50) return json({ error: 'files: 1-50 per call' }, 400)
    // registered rows belong to the (sole) admin
    const { data: admin } = await svc.from('profiles').select('id').eq('role', 'admin').limit(1).single()
    if (!admin) return json({ error: 'no admin profile' }, 500)
    let inserted = 0, foldersMade = 0, skipped = 0
    const folderCache = new Set<string>(
      ((await svc.from('drive_files').select('parent, filename').eq('drive', 'team').eq('is_folder', true)).data ?? [])
        .map((f) => (f.parent ? `${f.parent}/${f.filename}` : f.filename as string)),
    )
    for (const f of files) {
      const storagePath = String(f.storage_path ?? '')
      const filename = String(f.filename ?? '')
      const parent = String(f.parent ?? '')
      if (!storagePath || !filename) { skipped++; continue }
      // the object must really exist in the team bucket
      const dir = storagePath.split('/').slice(0, -1).join('/')
      const base = storagePath.split('/').pop()!
      const { data: found } = await svc.storage.from('team').list(dir, { search: base, limit: 1 })
      if (!found?.length) { skipped++; continue }
      // already registered? (exact object, or the same file re-imported from a
      // later zip: same name + folder + size ⇒ skip, don't duplicate)
      const { data: dupe } = await svc.from('drive_files').select('id').eq('storage_path', storagePath).limit(1)
      if (dupe?.length) { skipped++; continue }
      const { data: sameFile } = await svc.from('drive_files').select('id')
        .eq('drive', 'team').eq('filename', filename).eq('parent', parent)
        .eq('size_bytes', Number(f.size_bytes) || 0).eq('is_folder', false).limit(1)
      if (sameFile?.length) { skipped++; continue }
      // ensure ancestor folder rows exist (parent 'A/B/C' → rows A, A/B, A/B/C)
      const segs = parent ? parent.split('/') : []
      for (let i = 0; i < segs.length; i++) {
        const full = segs.slice(0, i + 1).join('/')
        if (folderCache.has(full)) continue
        await svc.from('drive_files').insert({
          drive: 'team', owner_id: admin.id, filename: segs[i], storage_path: null,
          content_type: '', size_bytes: 0, parent: segs.slice(0, i).join('/'), is_folder: true,
        })
        folderCache.add(full)
        foldersMade++
      }
      const { error } = await svc.from('drive_files').insert({
        drive: 'team', owner_id: admin.id, filename,
        storage_path: storagePath,
        content_type: String(f.content_type ?? 'application/octet-stream'),
        size_bytes: Number(f.size_bytes) || 0,
        parent, is_folder: false,
      })
      if (error) skipped++
      else inserted++
    }
    return json({ inserted, folders: foldersMade, skipped })
  }

  // ── search_targets: claim the oldest pending search request (NAS) ──
  if (body.mode === 'search_targets') {
    if (!cron) return json({ error: 'cron only' }, 403)
    const { data, error } = await svc.rpc('claim_doc_search')
    if (error) return json({ error: error.message }, 500)
    const req = Array.isArray(data) ? data[0] : null
    return json({ request: req ?? null })
  }

  // ── search_complete: embed → match → store results (NAS returns the vector) ──
  if (body.mode === 'search_complete') {
    if (!cron) return json({ error: 'cron only' }, 403)
    const id = Number(body.request_id)
    if (!id) return json({ error: 'request_id required' }, 400)
    const emb = body.query_embedding
    if (!Array.isArray(emb) || emb.length === 0) {
      await svc.rpc('complete_doc_search', { p_id: id, p_results: null, p_error: String(body.worker_error ?? 'no embedding') })
      return json({ ok: true, stored: 'error' })
    }
    // entity_type filter comes from the request row, not the worker payload
    const { data: reqRow } = await svc.from('doc_search_requests').select('entity_type').eq('id', id).single()
    const { data: matches, error } = await svc.rpc('match_document_embeddings', {
      p_embedding: JSON.stringify(emb),
      p_count: Number(body.count) || 12,
      p_entity_type: reqRow?.entity_type ?? null,
    })
    if (error) {
      await svc.rpc('complete_doc_search', { p_id: id, p_results: null, p_error: error.message })
      return json({ error: error.message }, 500)
    }
    await svc.rpc('complete_doc_search', { p_id: id, p_results: matches ?? [], p_error: null })
    return json({ ok: true, stored: (matches ?? []).length })
  }

  return json({ error: 'unknown mode' }, 400)
}))

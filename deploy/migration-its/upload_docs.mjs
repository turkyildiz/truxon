// Phase 2: upload transferred ITS files into Truxon storage + documents table.
// Usage: node upload_docs.mjs <admin_email> <admin_password>
// Reads files/<itsEditId>/<fileId>__<name> and load_id_map.json.
import { createClient } from '@supabase/supabase-js'
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const DIR = new URL('.', import.meta.url).pathname
const env = Object.fromEntries(
  readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const sb = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)
const [email, password] = process.argv.slice(2)
const { error: loginErr } = await sb.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('login failed:', loginErr.message); process.exit(1) }
const { data: userData } = await sb.auth.getUser()

const idMap = JSON.parse(readFileSync(DIR + 'load_id_map.json', 'utf8'))
const already = new Set()
{
  // resume-safe: skip files already uploaded (match by filename+entity)
  let from = 0
  for (;;) {
    const { data } = await sb.from('documents').select('entity_id, filename').eq('entity_type', 'load').range(from, from + 999)
    if (!data?.length) break
    data.forEach((d) => already.add(d.entity_id + '|' + d.filename))
    if (data.length < 1000) break
    from += 1000
  }
}

const MIME = { pdf: 'application/pdf', jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp', heic: 'image/heic', doc: 'application/msword', docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', xls: 'application/vnd.ms-excel', xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }
const docType = (name) => {
  if (/rate|conf|dispatch|order|tender|load_conf/i.test(name)) return 'Rate Confirmation'
  if (/pod|bol|signed|delivery|receipt/i.test(name)) return 'POD'
  if (/\.(jpe?g|png|heic|webp|gif)$/i.test(name)) return 'Photo'
  return 'Other'
}

let uploaded = 0, skipped = 0, failed = 0
const failures = []
const dirs = readdirSync(join(DIR, 'files'))
for (const its of dirs) {
  const loadId = idMap[its]
  if (!loadId) { failures.push({ its, reason: 'no truxon load id' }); continue }
  for (const f of readdirSync(join(DIR, 'files', its))) {
    const original = f.replace(/^\d+__/, '')
    if (already.has(loadId + '|' + original)) { skipped++; continue }
    const full = join(DIR, 'files', its, f)
    if (statSync(full).size === 0) { failures.push({ its, f, reason: 'empty file' }); continue }
    const ext = (original.split('.').pop() || '').toLowerCase()
    const safe = original.replace(/[^A-Za-z0-9._-]/g, '_')
    const path = `load/${loadId}/${f.split('__')[0]}_${safe}`
    const buf = readFileSync(full)
    const { error: upErr } = await sb.storage.from('documents').upload(path, buf, { contentType: MIME[ext] || 'application/octet-stream', upsert: true })
    if (upErr) { failed++; failures.push({ its, f, reason: upErr.message }); continue }
    const { error: metaErr } = await sb.from('documents').insert({
      entity_type: 'load', entity_id: loadId, doc_type: docType(original),
      filename: original, storage_path: path, content_type: MIME[ext] || 'application/octet-stream',
      size_bytes: buf.length, uploaded_by: userData.user?.id,
    })
    if (metaErr) { failed++; failures.push({ its, f, reason: metaErr.message }); continue }
    uploaded++
    if (uploaded % 100 === 0) console.log(`uploaded ${uploaded}…`)
  }
}
writeFileSync(DIR + 'upload_failures.json', JSON.stringify(failures, null, 1))
console.log(`done. uploaded: ${uploaded}, skipped(dupe): ${skipped}, failed: ${failed} (upload_failures.json)`)

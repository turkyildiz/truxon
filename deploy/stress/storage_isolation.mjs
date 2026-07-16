// Storage / drive isolation probe. Authenticated as admin/owner, verify that
// personal-bucket and team-bucket storage policies + drive_files RLS enforce
// per-uid isolation. Reads env + credentials, exercises 5 sub-vectors, and
// cleans up everything it creates. See supabase/migrations/20260716230001_drives.sql
import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const [email, password] = process.argv.slice(2)
const c = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)
const { data: auth, error: loginErr } = await c.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('LOGIN FAILED:', loginErr.message); process.exit(1) }
const myUid = auth.user.id
const FAKE = '00000000-0000-0000-0000-000000000000'
console.log('my uid =', myUid)

const results = {}
const body = new Blob([`stress test ${Date.now()}`], { type: 'text/plain' })
const stamp = Date.now()

// helper: classify a storage error/success into isolation outcome
const j = (o) => JSON.stringify(o && (o.message || o.error || o.statusCode || o) )

// (1) upload to 'personal' under a FOREIGN uid prefix -> must be REJECTED
{
  const path = `${FAKE}/stress_${stamp}.txt`
  const { data, error } = await c.storage.from('personal').upload(path, body, { upsert: false })
  results.personal_foreign_upload = { path, rejected: !!error, error: error?.message || null, data: data || null }
  console.log('(1) personal foreign upload rejected =', !!error, error?.message || '')
  if (!error) { // if it somehow succeeded, clean it up immediately
    await c.storage.from('personal').remove([path])
  }
}

// (2) upload to 'personal' under MY uid prefix -> OK, then delete
{
  const path = `${myUid}/stress_${stamp}.txt`
  const { error: upErr } = await c.storage.from('personal').upload(path, body, { upsert: true })
  let delErr = null
  if (!upErr) { const r = await c.storage.from('personal').remove([path]); delErr = r.error?.message || null }
  results.personal_own_upload = { path, uploaded: !upErr, uploadError: upErr?.message || null, deleted: !upErr && !delErr, deleteError: delErr }
  console.log('(2) personal own upload ok =', !upErr, upErr?.message || '', '| deleted =', !upErr && !delErr)
}

// (3) try to READ / download an object under a fake other-user prefix in 'personal' -> denied
{
  const path = `${FAKE}/stress_${stamp}.txt`
  const { data, error } = await c.storage.from('personal').download(path)
  // also try signed url + list of the foreign prefix
  const { data: sData, error: sErr } = await c.storage.from('personal').createSignedUrl(path, 60)
  const { data: lData, error: lErr } = await c.storage.from('personal').list(FAKE)
  // download of nonexistent-but-denied should not return real bytes; capture size
  let gotBytes = null
  if (data) { try { gotBytes = (await data.arrayBuffer()).byteLength } catch { gotBytes = 'blob' } }
  results.personal_foreign_read = {
    path,
    download_denied: !!error || gotBytes === 0 || gotBytes === null,
    download_error: error?.message || null, download_bytes: gotBytes,
    signedurl_denied: !!sErr, signedurl_error: sErr?.message || null, signedurl: sData?.signedUrl ? 'ISSUED' : null,
    list_foreign_count: Array.isArray(lData) ? lData.length : null, list_error: lErr?.message || null,
  }
  console.log('(3) personal foreign download denied =', !!error, '| signedUrl denied =', !!sErr, '| list foreign returned', Array.isArray(lData) ? lData.length : lErr?.message, 'entries')
}

// (4a) team bucket: upload under MY uid prefix -> OK
{
  const path = `${myUid}/stress_team_${stamp}.txt`
  const { error: upErr } = await c.storage.from('team').upload(path, body, { upsert: true })
  let delErr = null
  if (!upErr) { const r = await c.storage.from('team').remove([path]); delErr = r.error?.message || null }
  results.team_own_upload = { path, uploaded: !upErr, uploadError: upErr?.message || null, cleaned: !upErr && !delErr }
  console.log('(4a) team own upload ok =', !upErr, upErr?.message || '')
}
// (4b) team bucket: upload under a FOREIGN uid prefix -> must be REJECTED
{
  const path = `${FAKE}/stress_team_${stamp}.txt`
  const { data, error } = await c.storage.from('team').upload(path, body, { upsert: false })
  results.team_foreign_upload = { path, rejected: !!error, error: error?.message || null }
  console.log('(4b) team foreign upload rejected =', !!error, error?.message || '')
  if (!error) { await c.storage.from('team').remove([path]) }
}

// (5) insert drive_files row: drive='personal', owner_id = FAKE uid -> RLS must BLOCK
{
  const { data, error } = await c.from('drive_files').insert({
    drive: 'personal', owner_id: FAKE, filename: 'stress.txt',
    storage_path: `${FAKE}/stress_row_${stamp}.txt`, content_type: 'text/plain', size_bytes: 1,
  }).select('id')
  results.drive_files_personal_foreign_owner = { blocked: !!error || !data?.length, error: error?.message || null, inserted: data || null }
  console.log('(5) drive_files personal foreign owner blocked =', !!error || !data?.length, error?.message || '')
  if (data?.length) { await c.from('drive_files').delete().in('id', data.map((r) => r.id)) } // cleanup if it leaked
}

// Extra: team drive_files row with foreign owner_id (team_insert check requires owner_id = auth.uid())
{
  const { data, error } = await c.from('drive_files').insert({
    drive: 'team', owner_id: FAKE, filename: 'stress.txt',
    storage_path: `${FAKE}/stress_teamrow_${stamp}.txt`, content_type: 'text/plain', size_bytes: 1,
  }).select('id')
  results.drive_files_team_foreign_owner = { blocked: !!error || !data?.length, error: error?.message || null, inserted: data || null }
  console.log('(x) drive_files team foreign owner blocked =', !!error || !data?.length, error?.message || '')
  if (data?.length) { await c.from('drive_files').delete().in('id', data.map((r) => r.id)) }
}

console.log('\n=== RESULTS JSON ===')
console.log(JSON.stringify(results, null, 1))

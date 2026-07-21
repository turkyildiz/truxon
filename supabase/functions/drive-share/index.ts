// Public download door for drive share links: GET ?t=<token> → 302 redirect to
// a short-lived signed URL for that one file. Unauthenticated by design, but
// bounded: a token maps to exactly one file, and a revoked or expired token
// returns 404. Uses the service role; it never lists, traverses, or exposes
// anything but the single shared file the token names.
import { createClient } from 'jsr:@supabase/supabase-js@2'
import { withCors } from '../_shared/auth.ts'

const notFound = () =>
  new Response('This link is unavailable — it may have been removed or expired.', {
    status: 404,
    headers: { 'content-type': 'text/plain; charset=utf-8' },
  })

Deno.serve(withCors(async (req) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') return new Response('Method not allowed', { status: 405 })
  const token = new URL(req.url).searchParams.get('t') ?? ''
  if (!token || token.length < 16) return notFound()

  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: share } = await svc
    .from('drive_shares')
    .select('revoked, expires_at, file:drive_files(drive, storage_path, filename, is_folder)')
    .eq('token', token)
    .maybeSingle()

  const file = (share as { file?: { drive: string; storage_path: string | null; filename: string; is_folder: boolean } | null } | null)?.file
  if (
    !share ||
    share.revoked ||
    (share.expires_at && new Date(share.expires_at as string).getTime() < Date.now()) ||
    !file ||
    file.is_folder ||
    !file.storage_path
  ) {
    return notFound()
  }

  const { data: signed, error } = await svc.storage
    .from(file.drive)
    .createSignedUrl(file.storage_path, 120, { download: file.filename })
  if (error || !signed) return notFound()

  return new Response(null, { status: 302, headers: { Location: signed.signedUrl } })
}))

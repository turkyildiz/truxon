import { createClient, SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { AsyncLocalStorage } from 'node:async_hooks'

export interface Caller {
  client: SupabaseClient
  userId: string
  role: string
}

// GT-04 — browser calls are only legitimate from the SPA (plus local dev), so
// reflect the request Origin only when it's on this list instead of `*`.
// Non-browser callers (cron, curl, mobile) send no Origin and ignore CORS
// entirely, so they are unaffected. CORS_EXTRA_ORIGINS (comma-separated edge
// env) covers preview deploys without a code change.
const ORIGIN_ALLOWLIST = new Set([
  'https://truxon.com',
  'https://www.truxon.com',
  'http://localhost:5173',
  ...(Deno.env.get('CORS_EXTRA_ORIGINS') ?? '').split(',').map((s) => s.trim()).filter(Boolean),
])

// The request's Origin travels via AsyncLocalStorage so json()/corsResponse()
// keep their signatures at every existing call site; concurrent requests in
// one isolate each see their own value. Functions opt in by wrapping their
// handler in withCors(); without it, the fallback is the production origin.
const originStore = new AsyncLocalStorage<string>()

export function withCors(
  handler: (req: Request) => Response | Promise<Response>,
): (req: Request) => Response | Promise<Response> {
  return (req) => originStore.run(req.headers.get('Origin') ?? '', () => handler(req))
}

export function corsHeaders(): Record<string, string> {
  const origin = originStore.getStore() ?? ''
  return {
    'Access-Control-Allow-Origin': ORIGIN_ALLOWLIST.has(origin) ? origin : 'https://truxon.com',
    'Vary': 'Origin',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS',
  }
}

export function corsResponse(): Response {
  return new Response(null, { status: 204, headers: corsHeaders() })
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(), 'Content-Type': 'application/json' },
  })
}

/** Resolve the calling user and their Truxon role from the request JWT. */
export async function getCaller(req: Request): Promise<Caller | Response> {
  const client = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } },
  )
  const { data: userData, error } = await client.auth.getUser()
  if (error || !userData.user) return json({ error: 'Not authenticated' }, 401)

  const { data: profile } = await client
    .from('profiles')
    .select('role, is_active')
    .eq('id', userData.user.id)
    .single()
  if (!profile?.is_active) return json({ error: 'Account disabled' }, 403)

  return { client, userId: userData.user.id, role: profile.role }
}

/** Privileged cron/job door (S-01): the request must present the CRON_SECRET
 * header. The public anon JWT is NEVER authorization. Fail closed: with
 * CRON_SECRET unset, nothing passes. */
export function requireCron(req: Request): boolean {
  const secret = Deno.env.get('CRON_SECRET') ?? ''
  const got = req.headers.get('x-cron-key') ?? ''
  if (!timingSafeEqualStr(got, secret)) { maybeHoneytoken(got); return false }
  return true
}

/** Mint an RLS-scoped session for `email` (magiclink generate+verify, no email
 * actually sent). Lets background jobs write AS a real user instead of the
 * RLS-bypassing service role, so row policies stay the authority even when the
 * data being written was chosen by untrusted document text (review LOW). */
export async function mintUserSession(
  svc: SupabaseClient, email: string,
): Promise<{ client: SupabaseClient; userId: string } | null> {
  const { data: link, error } = await svc.auth.admin.generateLink({ type: 'magiclink', email })
  if (error || !link?.properties?.hashed_token) return null
  const url = Deno.env.get('SUPABASE_URL')!
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const anon = createClient(url, anonKey)
  const { data: sess, error: vErr } = await anon.auth.verifyOtp({
    type: 'magiclink', token_hash: link.properties.hashed_token,
  })
  if (vErr || !sess.session) return null
  const client = createClient(url, anonKey, {
    global: { headers: { Authorization: `Bearer ${sess.session.access_token}` } },
  })
  return { client, userId: sess.session.user.id }
}

/** Mint a session for the first active admin — for jobs with no human sender
 * (mailbox miners, sentinels) that still must not write RLS-bypassed. */
export async function mintAdminSession(
  svc: SupabaseClient,
): Promise<{ client: SupabaseClient; userId: string } | null> {
  const { data: profs } = await svc.from('profiles')
    .select('id').eq('role', 'admin').eq('is_active', true).limit(10)
  if (!profs?.length) return null
  const ids = new Set((profs as { id: string }[]).map((p) => p.id))
  const users = await listAllAuthUsers(svc)
  const admin = users.find((u) => ids.has(u.id) && u.email)
  if (!admin?.email) return null
  return mintUserSession(svc, admin.email)
}

/** Enumerate ALL auth users, paginating to exhaustion. `listUsers` returns only
 * one page (default 50, cap 1000), so a bare find/lookup silently misses anyone
 * past the cap once the roster grows (review LOW). 50-page backstop = 50k users. */
export async function listAllAuthUsers(
  client: SupabaseClient,
): Promise<Array<{ id: string; email?: string }>> {
  const all: Array<{ id: string; email?: string }> = []
  const perPage = 1000
  for (let page = 1; page <= 50; page++) {
    const { data, error } = await client.auth.admin.listUsers({ page, perPage })
    if (error || !data?.users?.length) break
    all.push(...data.users)
    if (data.users.length < perPage) break
  }
  return all
}

/** Constant-time string compare for shared secrets — one helper so every
 * privileged door (fuel-import, toll-sync, notify, watchdog) matches the
 * hardened requireCron instead of a leaky `===` (review LOW). Length is not
 * itself secret here, but we still fold it in without early-return timing. */
export function timingSafeEqualStr(a: string, b: string): boolean {
  if (!a || !b) return false
  let diff = a.length ^ b.length
  const n = Math.max(a.length, b.length)
  for (let i = 0; i < n; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0)
  return diff === 0
}

/** Salting: a REJECTED privileged secret might be one of the decoy keys the
 * honeypot serves — i.e. someone read the decoy and is now replaying it. Hash
 * the rejected value and (fire-and-forget) let the sentinel check it against
 * the honeytoken registry. We authenticate this internal call with our OWN
 * real CRON_SECRET; only long-enough candidates are checked, to avoid noise.
 * Never sends plaintext; never blocks the caller. */
function maybeHoneytoken(got: string): void {
  const secret = Deno.env.get('CRON_SECRET') ?? ''
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  if (!secret || !url || got.length < 20) return
  ;(async () => {
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(got))
    const hash = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('')
    await fetch(`${url}/functions/v1/trux-sentinel`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-cron-key': secret },
      body: JSON.stringify({ mode: 'honeytoken', hash }),
    })
  })().catch(() => {})
}

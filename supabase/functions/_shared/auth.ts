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
  if (!secret || got.length !== secret.length) return false
  let diff = 0
  for (let i = 0; i < secret.length; i++) diff |= secret.charCodeAt(i) ^ got.charCodeAt(i)
  return diff === 0
}

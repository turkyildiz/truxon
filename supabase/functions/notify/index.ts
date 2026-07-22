// Push registration + delivery for the Trux companion app.
//
// User JWT:
//   POST { action: "register", token, platform: "ios"|"android" }
//   POST { action: "unregister", token }
//
// Service role / webhook secret:
//   POST { action: "send", user_id, title, body, data?, urgent? }
//   POST { action: "notify_load", load_id, type: "paperwork"|"assignment", title?, body?, data?, urgent? }
//     urgent=true rings through Do-Not-Disturb (alarm channel + full-screen).
//     A new "assignment" defaults to urgent unless urgent:false is passed.
//
// Secrets (function only):
//   FCM_SERVICE_ACCOUNT_JSON — Firebase service account JSON for HTTP v1
//   APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC — optional APNs direct path
//   PUSH_ENV=sandbox|production
//   NOTIFY_WEBHOOK_SECRET — required for send/notify_load without service role

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json, timingSafeEqualStr, withCors } from '../_shared/auth.ts'

type Platform = 'ios' | 'android'

function adminClient() {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )
}

function isServiceRole(req: Request): boolean {
  const auth = req.headers.get('Authorization') ?? ''
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  return !!key && timingSafeEqualStr(auth, `Bearer ${key}`)
}

function webhookOk(req: Request, body: Record<string, unknown>): boolean {
  const secret = Deno.env.get('NOTIFY_WEBHOOK_SECRET')
  if (!secret) return false
  const hdr = req.headers.get('x-notify-secret') ?? req.headers.get('x-webhook-secret')
  if (hdr && timingSafeEqualStr(hdr, secret)) return true
  return typeof body.webhook_secret === 'string' && timingSafeEqualStr(body.webhook_secret, secret)
}

async function getFcmAccessToken(): Promise<string | null> {
  const raw = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON')
  if (!raw) return null
  let sa: { client_email: string; private_key: string; project_id: string }
  try {
    sa = JSON.parse(raw)
  } catch {
    return null
  }
  const now = Math.floor(Date.now() / 1000)
  const header = btoa(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
  const claim = btoa(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  })).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')

  // Web Crypto import of PEM private key
  const pem = sa.private_key.replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '').replace(/\s+/g, '')
  const keyData = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0))
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyData,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const sigBuf = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    new TextEncoder().encode(`${header}.${claim}`),
  )
  const sig = btoa(String.fromCharCode(...new Uint8Array(sigBuf)))
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
  const jwt = `${header}.${claim}.${sig}`

  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  })
  if (!tokenRes.ok) return null
  const data = await tokenRes.json()
  return data.access_token as string
}

async function sendFcm(
  projectId: string,
  accessToken: string,
  deviceToken: string,
  title: string,
  body: string,
  data?: Record<string, string>,
  urgent = false,
): Promise<{ ok: boolean; invalid?: boolean; detail?: string }> {
  // Urgent = ring through Do-Not-Disturb. On Android we target the app's
  // pre-created `dispatch_alarm` channel (configured bypassDnd + full-screen
  // intent client-side) and flag data.alarm so the FCM background handler can
  // raise a full-screen alarm even when the app is killed. On iOS we send an
  // interruption-level "time-sensitive"/critical push with the alarm sound.
  const payload: Record<string, unknown> = { token: deviceToken }
  if (urgent) {
    // DATA-ONLY on Android: no top-level/android `notification`, so the system
    // never auto-displays a plain notification. The app's FCM handler always
    // fires — foreground (onMessage) and background/killed (onBackgroundMessage,
    // kept alive by the tracking foreground service) — and renders the
    // full-screen `dispatch_alarm` alarm itself. title/body ride in `data`.
    payload.data = { ...(data ?? {}), alarm: '1', channel: 'dispatch_alarm', title, body }
    payload.android = { priority: 'high' }
    // iOS still gets a real alert (data-only wouldn't alarm on iOS).
    payload.apns = {
      headers: { 'apns-priority': '10', 'apns-push-type': 'alert' },
      payload: { aps: { alert: { title, body }, sound: 'default', 'interruption-level': 'time-sensitive' } },
    }
  } else {
    payload.notification = { title, body }
    payload.data = data ?? {}
    payload.android = { priority: 'high' }
  }
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ message: payload }),
    },
  )
  if (res.ok) return { ok: true }
  const text = await res.text()
  const invalid = /UNREGISTERED|INVALID_ARGUMENT|NOT_FOUND/i.test(text)
  return { ok: false, invalid, detail: text.slice(0, 400) }
}

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Invalid JSON' }, 400)
  }

  const action = String(body.action ?? '')

  // ---------- register / unregister (user JWT) ----------
  if (action === 'register' || action === 'unregister') {
    const caller = await getCaller(req)
    if (caller instanceof Response) return caller

    const token = String(body.token ?? '')
    if (!token) return json({ error: 'token required' }, 422)

    const admin = adminClient()
    if (action === 'unregister') {
      await admin.from('push_devices').delete().eq('user_id', caller.userId).eq('token', token)
      return json({ ok: true })
    }

    const platform = String(body.platform ?? '') as Platform
    if (platform !== 'ios' && platform !== 'android') {
      return json({ error: 'platform must be ios or android' }, 422)
    }

    const { error } = await admin.from('push_devices').upsert(
      { user_id: caller.userId, platform, token, updated_at: new Date().toISOString() },
      { onConflict: 'user_id,token' },
    )
    if (error) return json({ error: error.message }, 400)
    return json({ ok: true })
  }

  // ---------- send / notify_load (service, webhook, or staff JWT for notify_load) ----------
  if (action === 'send' || action === 'notify_load') {
    const staffCaller = action === 'notify_load' ? await getCaller(req) : null
    const staffOk =
      staffCaller &&
      !(staffCaller instanceof Response) &&
      ['admin', 'dispatcher', 'accountant'].includes(staffCaller.role)

    if (!isServiceRole(req) && !webhookOk(req, body) && !staffOk) {
      return json({ error: 'Unauthorized' }, 401)
    }
    // send to arbitrary user_id stays service/webhook only
    if (action === 'send' && !isServiceRole(req) && !webhookOk(req, body)) {
      return json({ error: 'Unauthorized' }, 401)
    }

    const admin = adminClient()
    let userId = body.user_id as string | undefined
    let title = String(body.title ?? 'Truxon')
    let message = String(body.body ?? '')
    let data: Record<string, string> = {}
    let urgent = body.urgent === true || body.urgent === 'true'

    if (body.data && typeof body.data === 'object') {
      for (const [k, v] of Object.entries(body.data as Record<string, unknown>)) {
        data[k] = String(v)
      }
    }

    if (action === 'notify_load') {
      const loadId = Number(body.load_id)
      if (!loadId) return json({ error: 'load_id required' }, 422)
      const { data: load, error } = await admin
        .from('loads')
        .select('id, load_number, driver_id, drivers(user_id, full_name)')
        .eq('id', loadId)
        .maybeSingle()
      if (error) return json({ error: error.message }, 400)
      if (!load?.driver_id) return json({ error: 'Load has no driver' }, 400)
      const drv = load.drivers as { user_id?: string; full_name?: string } | null
      userId = drv?.user_id
      if (!userId) return json({ error: 'Driver has no linked login' }, 400)
      const nType = String(body.type ?? 'assignment')
      data = { type: nType, load_id: String(loadId), ...data }
      if (!body.title) title = nType === 'paperwork' ? 'New paperwork' : 'Load update'
      if (!body.body) message = `Load ${load.load_number}`
      // A brand-new assignment should ring through DND so the driver sees it.
      if (nType === 'assignment' && body.urgent === undefined) urgent = true
    }

    if (!userId) return json({ error: 'user_id required' }, 422)

    const { data: devices, error: dErr } = await admin
      .from('push_devices')
      .select('id, token, platform')
      .eq('user_id', userId)
    if (dErr) return json({ error: dErr.message }, 400)
    if (!devices?.length) return json({ ok: true, sent: 0, note: 'no devices' })

    const fcmRaw = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON')
    let projectId = ''
    try {
      projectId = fcmRaw ? JSON.parse(fcmRaw).project_id : ''
    } catch { /* ignore */ }
    const accessToken = await getFcmAccessToken()
    console.log('notify.send begin', JSON.stringify({
      user_id: userId, devices: devices.length, urgent,
      project_id: projectId, has_access_token: !!accessToken,
    }))

    let sent = 0
    const errors: string[] = []
    for (const dev of devices) {
      if (!accessToken || !projectId) {
        errors.push('FCM not configured')
        break
      }
      const result = await sendFcm(projectId, accessToken, dev.token, title, message, data, urgent)
      console.log('notify.fcm', JSON.stringify({ platform: dev.platform, ok: result.ok, invalid: result.invalid, detail: result.detail }))
      if (result.ok) {
        sent++
      } else {
        if (result.invalid) {
          await admin.from('push_devices').delete().eq('id', dev.id)
        }
        errors.push(result.detail ?? 'send failed')
      }
    }

    return json({ ok: true, sent, errors: errors.slice(0, 5) })
  }

  return json({ error: 'Unknown action' }, 400)
}))

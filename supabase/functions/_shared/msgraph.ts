// Microsoft Graph helpers shared by trux-inbox and watchdog.
// Client-credentials flow against the tenant in MSGRAPH_* secrets.

export const TRUX_MAILBOX = Deno.env.get('TRUX_MAILBOX') ?? 'trux@truxon.com'
const GRAPH = 'https://graph.microsoft.com/v1.0'

export function graphConfigured(): boolean {
  return Boolean(Deno.env.get('MSGRAPH_TENANT_ID') && Deno.env.get('MSGRAPH_CLIENT_ID') && Deno.env.get('MSGRAPH_CLIENT_SECRET'))
}

export async function graphToken(): Promise<string> {
  const tenant = Deno.env.get('MSGRAPH_TENANT_ID')
  const id = Deno.env.get('MSGRAPH_CLIENT_ID')
  const secret = Deno.env.get('MSGRAPH_CLIENT_SECRET')
  if (!tenant || !id || !secret) throw new Error('not_configured')
  const res = await fetch(`https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: id,
      client_secret: secret,
      scope: 'https://graph.microsoft.com/.default',
      grant_type: 'client_credentials',
    }),
  })
  if (!res.ok) throw new Error(`Graph token failed: ${res.status} ${(await res.text()).slice(0, 300)}`)
  return (await res.json()).access_token
}

export async function graph(tok: string, path: string, init?: RequestInit): Promise<Response> {
  return await fetch(`${GRAPH}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
  })
}

/** Send a plain-text email from the Trux mailbox. */
export async function sendMailAsTrux(tok: string, to: string[], subject: string, body: string): Promise<boolean> {
  const res = await graph(tok, `/users/${encodeURIComponent(TRUX_MAILBOX)}/sendMail`, {
    method: 'POST',
    body: JSON.stringify({
      message: {
        subject,
        body: { contentType: 'Text', content: body },
        toRecipients: to.map((address) => ({ emailAddress: { address } })),
      },
      saveToSentItems: true,
    }),
  })
  return res.status === 202
}

/** Send an email with a file attachment (base64) from the Trux mailbox. */
export async function sendMailWithAttachment(
  tok: string,
  to: string[],
  subject: string,
  body: string,
  filename: string,
  contentBase64: string,
  contentType = 'application/pdf',
): Promise<{ ok: boolean; status: number; detail?: string }> {
  const res = await graph(tok, `/users/${encodeURIComponent(TRUX_MAILBOX)}/sendMail`, {
    method: 'POST',
    body: JSON.stringify({
      message: {
        subject,
        body: { contentType: 'Text', content: body },
        toRecipients: to.map((address) => ({ emailAddress: { address } })),
        attachments: [{
          '@odata.type': '#microsoft.graph.fileAttachment',
          name: filename,
          contentType,
          contentBytes: contentBase64,
        }],
      },
      saveToSentItems: true,
    }),
  })
  return { ok: res.status === 202, status: res.status, detail: res.ok ? undefined : (await res.text()).slice(0, 300) }
}

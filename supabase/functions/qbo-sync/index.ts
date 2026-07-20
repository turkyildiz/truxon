// QuickBooks Online sync — transition mode. QBO is the books of record; this
// function mirrors its invoices into Truxon so AR aging, Sentinel checks, and
// the C-suite metrics run on real payment truth. A push mode exists behind the
// QBO_PUSH_ENABLED flag for the later flip to Truxon-first invoicing.
//
// Modes (verify_jwt is OFF; every mode gates itself):
//   GET  ?mode=connect&token=<jwt>   admin only → 302 to Intuit consent
//   GET  ?mode=callback&code&state   Intuit redirect → exchange + save tokens
//   POST {mode:'pull'}               cron (anon bearer) or admin → backfill/CDC
//   POST {mode:'push', invoice_id}   admin + QBO_PUSH_ENABLED → create in QBO
//
// Intuit OAuth notes: refresh tokens ROTATE on every refresh — the new one is
// persisted before any API call so a crash can't strand the connection.
import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { getCaller, json } from '../_shared/auth.ts'

const AUTH_URL = 'https://appcenter.intuit.com/connect/oauth2'
const TOKEN_URL = 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer'
const API_BASE = 'https://quickbooks.api.intuit.com'
const BACKFILL_FROM = '2026-01-01'

function svc(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
}

function fnUrl(): string {
  return `${Deno.env.get('SUPABASE_URL')}/functions/v1/qbo-sync`
}

function basicAuth(): string {
  return 'Basic ' + btoa(`${Deno.env.get('QBO_CLIENT_ID')}:${Deno.env.get('QBO_CLIENT_SECRET')}`)
}

function html(body: string, status = 200): Response {
  return new Response(
    `<!doctype html><meta charset="utf-8"><body style="font-family:system-ui;display:grid;place-items:center;height:90vh"><div style="text-align:center">${body}</div></body>`,
    { status, headers: { 'Content-Type': 'text/html; charset=utf-8' } },
  )
}

interface Tokens {
  realm_id: string
  access_token: string
  refresh_token: string
  access_expires_at: string
  refresh_expires_at: string
}

async function saveTokens(s: SupabaseClient, t: Tokens, state?: string | null): Promise<void> {
  await s.from('qbo_connection').upsert({ id: 1, ...t, oauth_state: state ?? null })
}

/** Get a valid access token, refreshing (and persisting the rotation) if needed. */
async function accessToken(s: SupabaseClient): Promise<{ token: string; realm: string } | null> {
  const { data: c } = await s.from('qbo_connection').select('*').eq('id', 1).maybeSingle()
  if (!c) return null
  if (new Date(c.access_expires_at).getTime() - Date.now() > 120_000) {
    return { token: c.access_token, realm: c.realm_id }
  }
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { Authorization: basicAuth(), 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: c.refresh_token }),
  })
  if (!res.ok) return null
  const tok = await res.json()
  await saveTokens(s, {
    realm_id: c.realm_id,
    access_token: tok.access_token,
    refresh_token: tok.refresh_token,
    access_expires_at: new Date(Date.now() + tok.expires_in * 1000).toISOString(),
    refresh_expires_at: new Date(Date.now() + tok.x_refresh_token_expires_in * 1000).toISOString(),
  })
  return { token: tok.access_token, realm: c.realm_id }
}

async function qboGet(token: string, path: string): Promise<Record<string, unknown>> {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
  })
  if (!res.ok) throw new Error(`QBO ${res.status}: ${(await res.text()).slice(0, 300)}`)
  return await res.json()
}

// deno-lint-ignore no-explicit-any
function mapInvoice(inv: any): Record<string, unknown> {
  return {
    qbo_id: String(inv.Id),
    doc_number: String(inv.DocNumber ?? inv.Id),
    customer_qbo_id: String(inv.CustomerRef?.value ?? ''),
    customer_name: String(inv.CustomerRef?.name ?? 'Unknown'),
    txn_date: inv.TxnDate,
    due_date: inv.DueDate ?? inv.TxnDate,
    total: Number(inv.TotalAmt ?? 0),
    balance: Number(inv.Balance ?? 0),
    voided: Number(inv.TotalAmt ?? 0) === 0 && /voided/i.test(String(inv.PrivateNote ?? '')),
  }
}

// ── GL mirror: monthly P&L + balance-sheet snapshot ─────────────────────────
// Walks the QBO ProfitAndLoss report (summarized by month) into flat
// {month, account, grp, amount} rows for gl_upsert_monthly.
// deno-lint-ignore no-explicit-any
function parsePnl(report: any): Record<string, unknown>[] {
  const cols = (report?.Columns?.Column ?? []) as { ColTitle?: string; MetaData?: { Name: string; Value: string }[] }[]
  // month columns carry a StartDate; the first col is the account name, last is Total
  const monthCols: { idx: number; month: string }[] = []
  cols.forEach((c, idx) => {
    const start = c.MetaData?.find((m) => m.Name === 'StartDate')?.Value
    if (start) monthCols.push({ idx, month: start.slice(0, 8) + '01' })
  })
  const GRP: Record<string, string> = {
    Income: 'income', COGS: 'cogs', Expenses: 'expense',
    OtherIncome: 'other_income', OtherExpenses: 'other_expense',
  }
  const out: Record<string, unknown>[] = []
  // deno-lint-ignore no-explicit-any
  function walk(rows: any[], grp: string | null) {
    for (const r of rows ?? []) {
      const g = GRP[r.group as string] ?? grp
      if (r.type === 'Data' && g && r.ColData?.[0]?.value) {
        for (const mc of monthCols) {
          const v = Number(r.ColData[mc.idx]?.value ?? 0)
          if (v !== 0) out.push({ month: mc.month, account: String(r.ColData[0].value), grp: g, amount: v })
        }
      }
      if (r.Rows?.Row) walk(r.Rows.Row, g)
    }
  }
  walk(report?.Rows?.Row ?? [], null)
  return out
}

// Pick section totals out of the BalanceSheet report by their stable group names.
// deno-lint-ignore no-explicit-any
function parseBs(report: any): Record<string, number | null> {
  const totals: Record<string, number> = {}
  // deno-lint-ignore no-explicit-any
  function walk(rows: any[]) {
    for (const r of rows ?? []) {
      if (r.group && r.Summary?.ColData?.length) {
        const v = Number(r.Summary.ColData[r.Summary.ColData.length - 1]?.value ?? NaN)
        if (!Number.isNaN(v)) totals[r.group as string] = v
      }
      if (r.Rows?.Row) walk(r.Rows.Row)
    }
  }
  walk(report?.Rows?.Row ?? [])
  return {
    cash: totals.BankAccounts ?? null,
    ar: totals.AR ?? null,
    ap: totals.AP ?? null,
    current_assets: totals.CurrentAssets ?? null,
    current_liabilities: totals.CurrentLiabilities ?? null,
    total_assets: totals.TotalAssets ?? null,
    total_liabilities: totals.Liabilities ?? totals.TotalLiabilities ?? null,
    equity: totals.Equity ?? null,
  }
}

async function syncPnl(s: SupabaseClient, at: { token: string; realm: string }): Promise<Record<string, unknown>> {
  const start = `${new Date().getFullYear() - 1}-01-01`
  const end = new Date().toISOString().slice(0, 10)
  const pnl = await qboGet(at.token,
    `/v3/company/${at.realm}/reports/ProfitAndLoss?start_date=${start}&end_date=${end}&summarize_column_by=Month&accounting_method=Accrual&minorversion=75`)
  const rows = parsePnl(pnl)
  const { data: n, error } = await s.rpc('gl_upsert_monthly', { p_rows: rows })
  if (error) throw new Error(`gl upsert: ${error.message}`)

  const bs = await qboGet(at.token, `/v3/company/${at.realm}/reports/BalanceSheet?accounting_method=Accrual&minorversion=75`)
  const snap = parseBs(bs)
  const { error: bsErr } = await s.rpc('bs_upsert', { p: { as_of: end, ...snap } })
  if (bsErr) throw new Error(`bs upsert: ${bsErr.message}`)

  await s.from('qbo_sync_state').update({ last_pnl_at: new Date().toISOString() }).eq('id', 1)
  return { gl_rows: n, bs: snap.cash != null || snap.ap != null }
}

// ── Customer profile enrichment: fill blank Truxon customer fields from QBO ──
// QBO holds structured contact/address data for the customers it created (and
// the ones matched by name). Writes go through the same blanks-only RPC as the
// document enrichment, so the two sources cover each other — whichever fills a
// blank first wins, the other fills what's left.
async function syncCustomers(s: SupabaseClient, at: { token: string; realm: string }): Promise<Record<string, unknown>> {
  const page = 100
  let start = 1, matched = 0, filledTotal = 0, touched = 0
  const filledCustomers: Array<Record<string, unknown>> = []
  for (let guard = 0; guard < 60; guard++) {
    const q = `SELECT * FROM Customer STARTPOSITION ${start} MAXRESULTS ${page}`
    const out = await qboGet(at.token, `/v3/company/${at.realm}/query?query=${encodeURIComponent(q)}&minorversion=75`)
    // deno-lint-ignore no-explicit-any
    const rows = ((out?.QueryResponse as any)?.Customer ?? []) as any[]
    if (!rows.length) break
    for (const qc of rows) {
      // match by qbo_id first, then by exact name for customers without one
      type Cust = { id: number; company_name: string }
      let cust: Cust | null = null
      const { data: byId } = await s.from('customers').select('id, company_name').eq('qbo_id', String(qc.Id)).maybeSingle()
      if (byId) cust = byId as unknown as Cust
      if (!cust) {
        const name = String(qc.DisplayName || qc.CompanyName || '').trim()
        if (name) {
          const { data: byName } = await s.from('customers').select('id, company_name').ilike('company_name', name).is('qbo_id', null).limit(1)
          const hit = (byName?.[0] ?? null) as unknown as Cust | null
          if (hit) { cust = hit; await s.from('customers').update({ qbo_id: String(qc.Id) }).eq('id', hit.id) }
        }
      }
      if (!cust) continue
      matched++
      const a = qc.BillAddr ?? {}
      const cityLine = [a.City, a.CountrySubDivisionCode, a.PostalCode].filter(Boolean).join(', ')
      const billing = [a.Line1, a.Line2, cityLine].filter(Boolean).join('\n')
      const fields: Record<string, unknown> = {
        contact_person: [qc.GivenName, qc.FamilyName].filter(Boolean).join(' ') || null,
        phone: qc.PrimaryPhone?.FreeFormNumber ?? null,
        email: qc.PrimaryEmailAddr?.Address ?? null,
        fax: qc.Fax?.FreeFormNumber ?? null,
        secondary_phone: qc.AlternatePhone?.FreeFormNumber ?? null,
        billing_address: billing || null,
        notes: qc.Notes ?? null,
      }
      const { data: n } = await s.rpc('apply_customer_enrichment', {
        p_customer_id: cust.id, p_fields: fields, p_source_document_id: null, p_model: 'qbo:Customer',
      })
      const f = Number(n) || 0
      if (f > 0) { touched++; filledTotal += f; if (filledCustomers.length < 60) filledCustomers.push({ id: cust.id, company_name: cust.company_name, filled: f }) }
    }
    if (rows.length < page) break
    start += page
  }
  return { matched, filledTotal, touched, filledCustomers }
}

async function pull(s: SupabaseClient): Promise<Response> {
  const at = await accessToken(s)
  if (!at) {
    await s.from('qbo_sync_state').update({ last_error: 'not connected (or refresh failed)', last_pull_at: new Date().toISOString() }).eq('id', 1)
    return json({ error: 'QBO not connected' }, 409)
  }
  const { data: st } = await s.from('qbo_sync_state').select('*').eq('id', 1).single()
  const cdcStart = new Date(Date.now() - 60_000).toISOString() // watermark BEFORE queries: no gap
  let rows: Record<string, unknown>[] = []
  const voided: string[] = []

  try {
    if (!st?.backfilled) {
      // First pull: page through every invoice since BACKFILL_FROM.
      let startPos = 1
      for (let page = 0; page < 20; page++) {
        const q = `select * from Invoice where TxnDate >= '${BACKFILL_FROM}' orderby Id startposition ${startPos} maxresults 500`
        const out = await qboGet(at.token, `/v3/company/${at.realm}/query?query=${encodeURIComponent(q)}&minorversion=75`)
        // deno-lint-ignore no-explicit-any
        const batch = ((out.QueryResponse as any)?.Invoice ?? []) as any[]
        rows = rows.concat(batch.map(mapInvoice))
        if (batch.length < 500) break
        startPos += 500
      }
    } else {
      const since = st.last_cdc ?? new Date(Date.now() - 86_400_000).toISOString()
      const out = await qboGet(at.token, `/v3/company/${at.realm}/cdc?entities=Invoice&changedSince=${encodeURIComponent(since)}&minorversion=75`)
      // deno-lint-ignore no-explicit-any
      for (const resp of ((out.CDCResponse as any)?.[0]?.QueryResponse ?? []) as any[]) {
        for (const inv of resp.Invoice ?? []) {
          if (inv.status === 'Deleted') voided.push(String(inv.Id))
          else rows.push(mapInvoice(inv))
        }
      }
    }

    const { data: upserted, error } = await s.rpc('qbo_upsert_invoices', { p_rows: rows })
    if (error) throw new Error(error.message)
    let voidedN = 0
    if (voided.length) {
      const { data: vn } = await s.rpc('qbo_mark_voided', { p_qbo_ids: voided })
      voidedN = (vn as number) ?? 0
    }
    const result: Record<string, unknown> = { ...(upserted as Record<string, unknown>), voided: voidedN, fetched: rows.length }

    // GL mirror: refresh the monthly P&L + balance sheet about once a day
    // (best-effort — a report hiccup must not fail the invoice sync).
    const lastPnl = st?.last_pnl_at ? new Date(st.last_pnl_at).getTime() : 0
    if (Date.now() - lastPnl > 20 * 3600_000) {
      try {
        result.gl = await syncPnl(s, at)
      } catch (e) {
        result.gl_error = String(e).slice(0, 200)
      }
    }

    await s.from('qbo_sync_state').update({
      backfilled: true, last_cdc: cdcStart, last_pull_at: new Date().toISOString(),
      last_error: null, last_result: result,
    }).eq('id', 1)
    return json({ ok: true, ...result })
  } catch (e) {
    await s.from('qbo_sync_state').update({
      last_pull_at: new Date().toISOString(), last_error: String(e).slice(0, 500),
    }).eq('id', 1)
    return json({ error: String(e).slice(0, 300) }, 502)
  }
}

Deno.serve(async (req) => {
  const url = new URL(req.url)
  const s = svc()

  if (req.method === 'GET') {
    const mode = url.searchParams.get('mode')

    if (mode === 'connect') {
      // Browser navigation can't send headers — the app appends its JWT.
      const jwt = url.searchParams.get('token') ?? ''
      const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
        global: { headers: { Authorization: `Bearer ${jwt}` } },
      })
      const { data: u } = await anon.auth.getUser(jwt)
      if (!u?.user) return html('⛔ Sign in to Truxon first.', 401)
      const { data: prof } = await s.from('profiles').select('role').eq('id', u.user.id).single()
      if (prof?.role !== 'admin') return html('⛔ Admin only.', 403)

      const state = crypto.randomUUID()
      // stash the CSRF state (connection row may not exist yet → placeholder row)
      const { data: existing } = await s.from('qbo_connection').select('id').eq('id', 1).maybeSingle()
      if (existing) await s.from('qbo_connection').update({ oauth_state: state }).eq('id', 1)
      else {
        await s.from('qbo_connection').insert({
          id: 1, realm_id: '', access_token: '', refresh_token: '',
          access_expires_at: new Date(0).toISOString(), refresh_expires_at: new Date(0).toISOString(),
          oauth_state: state,
        })
      }
      const p = new URLSearchParams({
        client_id: Deno.env.get('QBO_CLIENT_ID')!,
        response_type: 'code',
        scope: 'com.intuit.quickbooks.accounting',
        redirect_uri: fnUrl(),
        state,
      })
      return Response.redirect(`${AUTH_URL}?${p}`, 302)
    }

    // Intuit redirects back with ?code&state&realmId (no mode param — default)
    const code = url.searchParams.get('code')
    if (code) {
      const state = url.searchParams.get('state')
      const realm = url.searchParams.get('realmId')
      const { data: c } = await s.from('qbo_connection').select('oauth_state').eq('id', 1).maybeSingle()
      if (!c || !state || c.oauth_state !== state) return html('⛔ OAuth state mismatch — start again from Truxon.', 400)
      const res = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { Authorization: basicAuth(), 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
        body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: fnUrl() }),
      })
      if (!res.ok) return html(`⛔ Token exchange failed (${res.status}).`, 502)
      const tok = await res.json()
      await saveTokens(s, {
        realm_id: realm ?? '',
        access_token: tok.access_token,
        refresh_token: tok.refresh_token,
        access_expires_at: new Date(Date.now() + tok.expires_in * 1000).toISOString(),
        refresh_expires_at: new Date(Date.now() + tok.x_refresh_token_expires_in * 1000).toISOString(),
      }, null)
      return html('✅ <h2>QuickBooks connected.</h2>The first sync runs within 30 minutes — you can close this tab and return to Truxon.')
    }
    return json({ error: 'Bad request' }, 400)
  }

  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  let body: { mode?: string; invoice_id?: number } = {}
  try { body = await req.json() } catch { /* empty */ }

  if (body.mode === 'pull') {
    // cron sends the public anon key. After the key rotation the env's
    // SUPABASE_ANON_KEY may be the new-format key, so instead of an exact
    // match, accept any bearer whose JWT payload is this project's anon role
    // (same trust level: the anon key is public; pull is read-only sync).
    const auth = req.headers.get('Authorization') ?? ''
    let isCron = false
    try {
      const payload = JSON.parse(atob((auth.replace('Bearer ', '').split('.')[1] ?? '').replace(/-/g, '+').replace(/_/g, '/')))
      const ref = new URL(Deno.env.get('SUPABASE_URL')!).hostname.split('.')[0]
      isCron = payload?.role === 'anon' && payload?.ref === ref
    } catch { /* not a JWT */ }
    if (!isCron) {
      const caller = await getCaller(req)
      if (caller instanceof Response) return caller
      if (caller.role !== 'admin') return json({ error: 'Admin only' }, 403)
    }
    return await pull(s)
  }

  if (body.mode === 'pnl') {
    // same gate as pull: cron anon bearer or an admin session
    const auth = req.headers.get('Authorization') ?? ''
    let ok = false
    try {
      const payload = JSON.parse(atob((auth.replace('Bearer ', '').split('.')[1] ?? '').replace(/-/g, '+').replace(/_/g, '/')))
      const ref = new URL(Deno.env.get('SUPABASE_URL')!).hostname.split('.')[0]
      ok = payload?.role === 'anon' && payload?.ref === ref
    } catch { /* not a JWT */ }
    if (!ok) {
      const caller = await getCaller(req)
      if (caller instanceof Response) return caller
      if (caller.role !== 'admin') return json({ error: 'Admin only' }, 403)
    }
    const at = await accessToken(s)
    if (!at) return json({ error: 'QBO not connected' }, 409)
    try {
      return json({ ok: true, ...(await syncPnl(s, at)) })
    } catch (e) {
      return json({ error: String(e).slice(0, 300) }, 502)
    }
  }

  if (body.mode === 'customers') {
    // same gate as pull/pnl: cron anon bearer or an admin session
    const auth = req.headers.get('Authorization') ?? ''
    let ok = false
    try {
      const payload = JSON.parse(atob((auth.replace('Bearer ', '').split('.')[1] ?? '').replace(/-/g, '+').replace(/_/g, '/')))
      const ref = new URL(Deno.env.get('SUPABASE_URL')!).hostname.split('.')[0]
      ok = payload?.role === 'anon' && payload?.ref === ref
    } catch { /* not a JWT */ }
    if (!ok) {
      const caller = await getCaller(req)
      if (caller instanceof Response) return caller
      if (caller.role !== 'admin') return json({ error: 'Admin only' }, 403)
    }
    const at = await accessToken(s)
    if (!at) return json({ error: 'QBO not connected' }, 409)
    try {
      return json({ ok: true, ...(await syncCustomers(s, at)) })
    } catch (e) {
      return json({ error: String(e).slice(0, 300) }, 502)
    }
  }

  if (body.mode === 'push') {
    if (Deno.env.get('QBO_PUSH_ENABLED') !== 'true') {
      return json({ error: 'Push mode is not enabled yet (transition period: QBO remains the invoice source)' }, 403)
    }
    const caller = await getCaller(req)
    if (caller instanceof Response) return caller
    if (caller.role !== 'admin') return json({ error: 'Admin only' }, 403)
    // Flip-time implementation lands with the switch; mirror-first for now.
    return json({ error: 'Push not implemented in transition mode' }, 501)
  }

  return json({ error: 'Unknown mode' }, 400)
})

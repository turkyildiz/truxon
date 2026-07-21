// toll-sync — pulls toll transactions from the PrePass Toll Transaction API and
// imports them into public.toll_transactions. Fully serverless: invoked by
// pg_cron (no NAS). Idempotent (keyed on PrePass tollId), so overlapping runs
// and a rolling window are safe.
//
// Auth to invoke this endpoint: TOLL_SYNC_KEY in the X-Toll-Key header (the
// cron sends it) OR an admin JWT (manual trigger). PrePass credentials live in
// secrets and never leave this function.
//
// Secrets:
//   PREPASS_CLIENT_ID, PREPASS_CLIENT_SECRET   API credentials (Token API v1)
//   PREPASS_ACCOUNT_NUMBERS                     comma-separated account number(s)
//   TOLL_SYNC_KEY                               shared key gating this endpoint
//   PREPASS_API_BASE      optional, default https://api.prepass.com
//   PREPASS_TOKEN_URL     optional, default <base>/token/v1/token  (confirm on the portal)
//   TOLL_LOOKBACK_DAYS    optional, default 14 (rolling postDate window)
//
// If PrePass secrets are absent the function no-ops ({skipped:'not configured'})
// so a scheduled cron is harmless before go-live.

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json, withCors } from '../_shared/auth.ts'

const BASE = (Deno.env.get('PREPASS_API_BASE') ?? 'https://api.prepass.com').replace(/\/$/, '')
const TOKEN_URL = Deno.env.get('PREPASS_TOKEN_URL') ?? `${BASE}/token/v1/token`
const LOOKBACK = Number(Deno.env.get('TOLL_LOOKBACK_DAYS') ?? 14)

const num = (v: unknown): number | null => {
  if (v == null || v === '') return null
  const n = Number(String(v).replace(/[$,]/g, ''))
  return Number.isFinite(n) ? n : null
}
// PrePass dates are "yyyy-mm-ddTHH:mm:ss" (no zone) or empty.
const ts = (v: unknown): string | null => {
  const s = String(v ?? '').trim()
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(s) ? s : null
}
const ymd = (d: Date) => d.toISOString().slice(0, 10)

async function prepassToken(): Promise<string> {
  const clientId = Deno.env.get('PREPASS_CLIENT_ID')!
  const clientSecret = Deno.env.get('PREPASS_CLIENT_SECRET')!
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ clientId, clientSecret }),
  })
  if (!res.ok) throw new Error(`PrePass token ${res.status}: ${(await res.text()).slice(0, 200)}`)
  const j = await res.json()
  const tok = j.access_token ?? j.accessToken ?? j.token ?? j.jwt
  if (!tok) throw new Error('PrePass token response had no token field')
  return tok
}

/** One PrePass transaction → a clean row for import_toll_transactions. */
function mapTx(t: Record<string, unknown>): Record<string, unknown> {
  return {
    toll_id: String(t.tollId ?? ''),
    account_number: num(t.accountNumber),
    account_name: t.accountName ?? '',
    bill_to_account_number: num(t.billToAccountNumber),
    bill_to_account_name: t.billToAccountName ?? '',
    post_date_time: ts(t.postDateTime),
    invoice_date_time: ts(t.invoiceDateTime),
    exit_date_time: ts(t.exitDateTime),
    entry_date_time: ts(t.entryDateTime),
    device_number: t.deviceNumber ?? '',
    vehicle_number: t.vehicleNumber ?? '',
    plate_number: t.plateNumber ?? '',
    toll_agency_name: t.tollAgencyName ?? '',
    toll_agency_state: t.tollAgencyState ?? '',
    billing_agency_code: t.billingAgencyCode ?? '',
    entry_plaza_code: t.entryPlazaCode ?? '',
    entry_plaza_name: t.entryPlazaName ?? '',
    exit_plaza_code: t.exitPlazaCode ?? '',
    exit_plaza_name: t.exitPlazaName ?? '',
    read_type: t.readType ?? '',
    toll_class: t.tollClass ?? '',
    toll_charge: num(t.tollCharge) ?? 0,
    toll_category: t.tollCategory ?? '',
    dispute_status: t.disputeStatus ?? '',
    raw: t,
  }
}

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  // Gate: shared key or admin JWT.
  const key = req.headers.get('X-Toll-Key')
  const expected = Deno.env.get('TOLL_SYNC_KEY')
  if (!(expected && key && key === expected)) {
    const caller = await getCaller(req)
    if (caller instanceof Response) return caller
    if (caller.role !== 'admin') return json({ error: 'Admin or toll key required' }, 403)
  }

  const body = await req.json().catch(() => ({}))

  // ── SFTP path: PrePass delivers CSVs over SFTP (not the API for this
  // account). The NAS parses each file into RPC-shaped rows and posts them
  // here; the service key + dedup/truck-match RPC stay server-side. ──
  if (body.mode === 'import_rows') {
    const rows = Array.isArray(body.rows) ? body.rows : []
    if (rows.length === 0) return json({ ok: true, received: 0 })
    const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
    const { data, error } = await svc.rpc('import_toll_transactions', { p_rows: rows })
    if (error) return json({ error: error.message }, 500)
    return json({ ok: true, ...(data as Record<string, unknown>) })
  }

  const clientId = Deno.env.get('PREPASS_CLIENT_ID')
  const accounts = Deno.env.get('PREPASS_ACCOUNT_NUMBERS')
  if (!clientId || !accounts) return json({ skipped: 'not configured (PREPASS_* secrets absent)' })
  const lookback = Number(body.lookback_days ?? LOOKBACK)
  const end = new Date()
  const start = new Date(end.getTime() - lookback * 86400_000)

  let tok: string
  try { tok = await prepassToken() } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 502)
  }

  // Page through the toll transactions for the window.
  const rows: Record<string, unknown>[] = []
  let page = 1, totalPages = 1
  do {
    const url = `${BASE}/tolltransaction/v1/transactions?startPostDate=${ymd(start)}&endPostDate=${ymd(end)}`
      + `&accountNumbers=${encodeURIComponent(accounts)}&pageNumber=${page}&pageSize=10000`
    const res = await fetch(url, { headers: { Authorization: `Bearer ${tok}` } })
    if (!res.ok) return json({ error: `PrePass tolls ${res.status}: ${(await res.text()).slice(0, 200)}`, imported: rows.length }, 502)
    const data = await res.json()
    for (const t of (data.transactions ?? []) as Record<string, unknown>[]) {
      const m = mapTx(t)
      if (m.toll_id) rows.push(m)
    }
    totalPages = Number(data.pageInfo?.totalPages ?? 1)
    page++
  } while (page <= totalPages && page <= 200) // hard cap: 2M rows

  if (rows.length === 0) return json({ ok: true, fetched: 0, note: 'no toll transactions in window' })

  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: result, error } = await svc.rpc('import_toll_transactions', { p_rows: rows })
  if (error) return json({ error: error.message, fetched: rows.length }, 500)

  return json({ ok: true, fetched: rows.length, ...(result as object) })
}))

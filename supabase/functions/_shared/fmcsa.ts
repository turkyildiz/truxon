// FMCSA carrier-number verification.
//
// Before ANY mc_number / usdot_number is written to a customer record, we confirm
// with the FMCSA QCMobile API that the number (a) is real and (b) belongs to a
// carrier whose name matches the customer we're about to write it to. This stops a
// vision/OCR digit-transposition (observed: USDOT 4187601 read as 4186701) from
// silently poisoning a customer's regulatory identifiers.
//
// FAIL-CLOSED: if there is no webKey, or the number isn't found, or the FMCSA name
// doesn't match the customer, the number is DROPPED (never written). A verified
// number is also CANONICALIZED to the FMCSA value, and a validated MC lookup will
// back-fill a blank USDOT from FMCSA's authoritative record.
//
// webKey: a free key from https://mobile.fmcsa.dot.gov/QCDevsite/docs/apiAccess ,
// provided as the FMCSA_WEBKEY edge secret. No key -> mc/usdot simply stop being
// written (contact fields are unaffected).

const BASE = 'https://mobile.fmcsa.dot.gov/qc/services/carriers'

const STOP = new Set(['inc', 'llc', 'ltd', 'co', 'corp', 'company', 'group', 'the', 'and', 'of',
  'logistics', 'transport', 'transportation', 'freight', 'trucking', 'carriers', 'carrier',
  'services', 'service', 'brokerage', 'broker', 'solutions', 'usa', 'dba', 'intl', 'international'])

export const digits = (s: unknown): string => String(s ?? '').replace(/\D/g, '')

export function nameTokens(s: unknown): Set<string> {
  return new Set(String(s ?? '').toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/)
    .filter((t) => t.length > 2 && !STOP.has(t)))
}

// True when the two names plausibly refer to the same company. We require that at
// least half of the customer's distinctive tokens appear in the FMCSA name (and at
// least one shared token), which tolerates DBA/word-order differences without
// matching unrelated carriers.
export function nameMatches(customer: unknown, fmcsaName: unknown): boolean {
  const want = nameTokens(customer)
  const got = nameTokens(fmcsaName)
  if (!want.size || !got.size) return false
  let shared = 0
  for (const t of want) if (got.has(t)) shared++
  // Match if the customer's distinctive tokens are mostly in the FMCSA name, OR the
  // FMCSA name's tokens are mostly in the customer name (handles a DBA/parent-company
  // suffix like "AFN, LLC / GlobalTranz" vs FMCSA "AFN LLC").
  return shared >= 1 && (shared / want.size >= 0.5 || shared / got.size >= 0.6)
}

export interface FmcsaCarrier {
  dotNumber?: number | string
  legalName?: string
  dbaName?: string
  phyStreet?: string
  phyCity?: string
  phyState?: string
  phyZipcode?: string
  allowedToOperate?: string
}

async function getCarrierJson(url: string): Promise<unknown> {
  try {
    const r = await fetch(url, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(8000) })
    if (!r.ok) return null
    return await r.json()
  } catch {
    return null
  }
}

// GET /carriers/{dot} -> { content: { carrier: {...} } }
export async function lookupByDot(dot: string, webKey: string): Promise<FmcsaCarrier | null> {
  const d = digits(dot)
  if (!d) return null
  const j = await getCarrierJson(`${BASE}/${d}?webKey=${encodeURIComponent(webKey)}`) as
    { content?: { carrier?: FmcsaCarrier } } | null
  return j?.content?.carrier ?? null
}

// GET /carriers/docket-number/{mc} -> { content: [ { carrier: {...} }, ... ] }
export async function lookupByMc(mc: string, webKey: string): Promise<FmcsaCarrier | null> {
  const m = digits(mc)
  if (!m) return null
  const j = await getCarrierJson(`${BASE}/docket-number/${m}?webKey=${encodeURIComponent(webKey)}`) as
    { content?: Array<{ carrier?: FmcsaCarrier }> } | null
  const first = Array.isArray(j?.content) ? j?.content[0]?.carrier : undefined
  return first ?? null
}

export interface ValidateOpts {
  webKey?: string
  // injectable for testing; default to the live FMCSA calls
  lookupDot?: (dot: string, webKey: string) => Promise<FmcsaCarrier | null>
  lookupMc?: (mc: string, webKey: string) => Promise<FmcsaCarrier | null>
}

// Returns a shallow copy of `fields` with mc_number / usdot_number kept ONLY when
// FMCSA-verified (and canonicalized), plus human-readable notes about every
// drop/verify decision. All other fields pass through untouched.
export async function validateCarrierNumbers(
  fields: Record<string, unknown>,
  companyName: unknown,
  opts: ValidateOpts = {},
): Promise<{ fields: Record<string, unknown>; notes: string[] }> {
  const out = { ...fields }
  const notes: string[] = []
  const webKey = opts.webKey ?? ''
  const doDot = opts.lookupDot ?? lookupByDot
  const doMc = opts.lookupMc ?? lookupByMc

  const hasDot = out.usdot_number != null && digits(out.usdot_number) !== ''
  const hasMc = out.mc_number != null && digits(out.mc_number) !== ''
  if (!hasDot && !hasMc) return { fields: out, notes }

  if (!webKey) {
    if (hasDot) { delete out.usdot_number; notes.push('USDOT dropped: no FMCSA_WEBKEY to verify') }
    if (hasMc) { delete out.mc_number; notes.push('MC dropped: no FMCSA_WEBKEY to verify') }
    return { fields: out, notes }
  }

  // USDOT: verify the number resolves to a carrier whose name matches this customer.
  if (hasDot) {
    const dot = digits(out.usdot_number)
    const rec = await doDot(dot, webKey)
    if (!rec) { delete out.usdot_number; notes.push(`USDOT ${dot} dropped: not found in FMCSA`) }
    else if (!nameMatches(companyName, rec.legalName ?? rec.dbaName)) {
      delete out.usdot_number
      notes.push(`USDOT ${dot} dropped: FMCSA says "${rec.legalName ?? rec.dbaName}", not "${companyName}"`)
    } else {
      out.usdot_number = String(rec.dotNumber ?? dot)
      notes.push(`USDOT ${out.usdot_number} verified via FMCSA`)
    }
  }

  // MC (docket): same check; a verified MC also back-fills a blank USDOT from the
  // authoritative FMCSA record (blanks-only write downstream keeps this safe).
  if (hasMc) {
    const mc = digits(out.mc_number)
    const rec = await doMc(mc, webKey)
    if (!rec) { delete out.mc_number; notes.push(`MC ${mc} dropped: not found in FMCSA`) }
    else if (!nameMatches(companyName, rec.legalName ?? rec.dbaName)) {
      delete out.mc_number
      notes.push(`MC ${mc} dropped: FMCSA says "${rec.legalName ?? rec.dbaName}", not "${companyName}"`)
    } else {
      out.mc_number = mc
      notes.push(`MC ${mc} verified via FMCSA`)
      if ((out.usdot_number == null || digits(out.usdot_number) === '') && rec.dotNumber) {
        out.usdot_number = String(rec.dotNumber)
        notes.push(`USDOT ${out.usdot_number} back-filled from FMCSA (MC ${mc})`)
      }
    }
  }

  return { fields: out, notes }
}

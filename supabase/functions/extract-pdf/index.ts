// AI-assisted extraction of load details from rate confirmation PDFs.
// Pipeline: unpdf pulls the text, an OpenRouter/Groq-compatible LLM
// structures it. Scanned PDFs (no text layer) fall back to a vision model:
// the browser renders the pages to JPEGs and sends them as page0..pageN.
// Without LLM_API_KEY the raw text is still returned so the dispatcher can
// copy/paste.
//
// Env: LLM_API_KEY (required for AI), optional LLM_BASE_URL (default
// OpenRouter), LLM_MODEL (text), LLM_VISION_MODEL (scanned docs).

import { extractText, getDocumentProxy } from 'npm:unpdf@0.12.1'
import { corsResponse, getCaller, json } from '../_shared/auth.ts'

function extractionPrompt(carrierName: string): string {
  return `You extract structured data from a trucking rate confirmation addressed to the carrier "${carrierName}".
Respond with ONLY a JSON object (no markdown fences) with these keys:
- customer_name: the broker or shipper company ISSUING the load. Never "${carrierName}" — that is the carrier being hired, usually next to labels like "Carrier:" or MC#.
- reference_number: the broker's own load identifier as a string — labels like "Load Number", "Load #", "Order #", "PO#", "PRO#", "Reference". Pick the primary one for THIS shipment, not the carrier's MC/DOT numbers.
- pickup_number: the pickup/PU number the driver must give at the shipper (labels like "PU#", "Pickup Number", "Pickup/Delivery Number" at the pickup stop). null if none.
- delivery_number: the delivery/confirmation/appointment number for the receiver (labels like "Delivery #", "Confirmation #", "Pickup/Delivery Number" at the delivery stop). null if none.
- pickup_address: first pickup — facility name, street, city, state, zip (whatever is present)
- pickup_time: pickup date/time as "YYYY-MM-DDTHH:MM" (no timezone). If only a window is given (e.g. "FCFS 08:00-15:00"), use the window start. If only a date is known, use "YYYY-MM-DDT00:00". null only if no date at all.
- delivery_address: final delivery — same format as pickup_address
- delivery_time: delivery date/time, same rules as pickup_time (use the appointment time if one is set)
- rate: TOTAL carrier pay in dollars as a plain number — the all-in amount ("Total", "Total Cost", "Cost", line haul + fuel surcharge + accessorials). Not a per-mile rate.
- special_terms: short string (max 300 chars) with what a dispatcher must know: required equipment, temperature, tracking demands, unusual penalties. null if nothing notable.
- stops: ordered array of EVERY stop on the load (multi-stop loads have more than two). Each element: {"type": "pickup"|"delivery", "facility": company/location name or null, "address": street/city/state/zip or null, "datetime": "YYYY-MM-DDTHH:MM" or null (same rules as pickup_time), "reference": that stop's PU#/delivery#/PO or null}.
Two-digit years are 20xx. Use null for anything genuinely absent.`
}

function customerPrompt(carrierName: string): string {
  return `You extract the BROKER/CUSTOMER company profile from a trucking document (rate confirmation, carrier setup packet, invoice…) addressed to the carrier "${carrierName}".
Respond with ONLY a JSON object (no markdown fences) with these keys:
- company_name: the broker or shipper company that issued the document. Never "${carrierName}" — that is the carrier receiving it.
- contact_person: the primary contact/broker rep name. null if none.
- phone: their phone number. null if none.
- email: their email address. null if none.
- billing_address: the remit-to / bill-to mailing address for invoices if given, otherwise the company's main address. null if none.
- payment_terms: payment terms as stated (e.g. "Net 30", "28 days", "30 days after POD"). null if none.
- mc_number: the BROKER's MC number if shown (not the carrier's). null if none.
- notes: short string (max 300 chars) with billing quirks worth remembering — invoicing portals, required paperwork, quick-pay options. null if nothing notable.
Use null for anything genuinely absent.`
}

const TEXT_HEAD = 7000
const TEXT_TAIL = 4000

/** Brokers bury the money next to the signature block, so when a document is
 * too long keep the start AND the end rather than truncating blindly. */
function sliceText(text: string): string {
  if (text.length <= TEXT_HEAD + TEXT_TAIL + 100) return text
  return text.slice(0, TEXT_HEAD) + '\n...[middle of document omitted]...\n' + text.slice(-TEXT_TAIL)
}

type LlmContent = string | Array<{ type: string; text?: string; image_url?: { url: string } }>

async function callLlm(apiKey: string, model: string, content: LlmContent): Promise<string> {
  const url = `${Deno.env.get('LLM_BASE_URL') ?? 'https://openrouter.ai/api/v1'}/chat/completions`
  const body = (jsonMode: boolean) =>
    JSON.stringify({
      model,
      messages: [{ role: 'user', content }],
      temperature: 0,
      ...(jsonMode ? { response_format: { type: 'json_object' } } : {}),
    })

  let jsonMode = true
  for (let attempt = 1; ; attempt++) {
    let resp: Response
    try {
      resp = await fetch(url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
        body: body(jsonMode),
        signal: AbortSignal.timeout(45_000),
      })
    } catch (err) {
      // Hung/dropped connection — retry instead of riding out the gateway timeout.
      if (attempt < 3) continue
      throw new Error(`LLM API unreachable: ${err}`)
    }
    if (resp.ok) {
      const data = await resp.json()
      return data.choices[0].message.content.trim()
    }
    await resp.body?.cancel()
    // Some providers reject response_format for some models — retry without it.
    if (resp.status === 400 && jsonMode) {
      jsonMode = false
      continue
    }
    // Per-minute token limits (Groq free tier) surface as 429 — wait and retry.
    if ((resp.status === 429 || resp.status >= 500) && attempt < 3) {
      const retryAfter = Number(resp.headers.get('retry-after'))
      await new Promise((r) => setTimeout(r, Math.min(retryAfter > 0 ? retryAfter * 1000 : attempt * 4000, 15000)))
      continue
    }
    throw new Error(`LLM API returned ${resp.status}`)
  }
}

/** Call the model, and if the reply isn't parseable JSON (tabular rate cons
 * sometimes make small models echo the table), retry once with a sharper
 * instruction before giving up. */
async function extractFields(apiKey: string, model: string, content: LlmContent): Promise<Record<string, unknown>> {
  try {
    return parseFields(await callLlm(apiKey, model, content))
  } catch {
    const stricter =
      typeof content === 'string'
        ? content + '\n\nIMPORTANT: Your ENTIRE response must be one valid JSON object. No prose, no tables, no explanations.'
        : [...content, { type: 'text', text: 'IMPORTANT: Your ENTIRE response must be one valid JSON object. No prose, no tables, no explanations.' }]
    return parseFields(await callLlm(apiKey, model, stricter))
  }
}

function parseFields(content: string): Record<string, unknown> {
  let c = content
  if (c.startsWith('```')) c = c.replace(/^```(json)?/, '').replace(/```$/, '').trim()
  // Tolerate stray prose around the object — grab the outermost braces.
  const start = c.indexOf('{')
  const end = c.lastIndexOf('}')
  if (start >= 0 && end > start) c = c.slice(start, end + 1)
  return JSON.parse(c)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()

  const caller = await getCaller(req)
  if (caller instanceof Response) return caller
  if (!['admin', 'dispatcher'].includes(caller.role)) {
    return json({ error: 'Not enough permissions' }, 403)
  }

  // Cap AI extractions per user to prevent runaway LLM spend
  // (EXTRACT_RATE_MAX overrides the default 30/hour).
  const rateMax = Number(Deno.env.get('EXTRACT_RATE_MAX')) || 30
  const { data: allowed } = await caller.client.rpc('check_rate_limit', {
    p_action: 'extract_pdf',
    p_max: rateMax,
    p_window: '01:00:00',
  })
  if (allowed === false) {
    return json({ error: `Rate limit reached (${rateMax} extractions/hour). Try again later.` }, 429)
  }

  const form = await req.formData()
  const file = form.get('file')
  if (!(file instanceof File)) return json({ error: 'Upload a PDF file as "file"' }, 422)
  if (file.size > 15 * 1024 * 1024) return json({ error: 'PDF too large (15 MB max)' }, 413)

  // Optional page images (JPEG/PNG) rendered client-side for scanned PDFs.
  const pageImages: File[] = []
  for (let i = 0; i < 5; i++) {
    const img = form.get(`page${i}`)
    if (img instanceof File && img.size <= 3 * 1024 * 1024) pageImages.push(img)
  }

  let text = ''
  try {
    const pdf = await getDocumentProxy(new Uint8Array(await file.arrayBuffer()))
    const extracted = await extractText(pdf, { mergePages: true })
    text = extracted.text
  } catch (err) {
    if (pageImages.length === 0) return json({ raw_text: '', fields: null, error: `Could not read PDF: ${err}` })
  }

  const scanned = !text.trim()
  if (scanned && pageImages.length === 0) {
    // The frontend renders the pages and retries with page0..pageN attached.
    return json({ raw_text: '', fields: null, needs_images: true, error: 'PDF contains no extractable text (scanned image?)' })
  }

  const apiKey = Deno.env.get('LLM_API_KEY')
  if (!apiKey) {
    return json({ raw_text: text, fields: null, error: 'No LLM API key configured — fill fields manually' })
  }

  const { data: settings } = await caller.client.from('company_settings').select('company_name').eq('id', 1).maybeSingle()
  const carrier = settings?.company_name || 'the carrier'
  // mode=customer extracts the broker's company profile (Customers quick-add)
  // instead of load details.
  const prompt = form.get('mode') === 'customer' ? customerPrompt(carrier) : extractionPrompt(carrier)

  try {
    let fields: Record<string, unknown>
    if (scanned) {
      const model = Deno.env.get('LLM_VISION_MODEL') ?? 'meta-llama/llama-4-scout-17b-16e-instruct'
      const parts: LlmContent = [{ type: 'text', text: prompt + '\n\nThe document pages follow as images.' }]
      for (const img of pageImages) {
        const bytes = new Uint8Array(await img.arrayBuffer())
        let binary = ''
        for (let i = 0; i < bytes.length; i += 0x8000) {
          binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
        }
        parts.push({ type: 'image_url', image_url: { url: `data:${img.type || 'image/jpeg'};base64,${btoa(binary)}` } })
      }
      fields = await extractFields(apiKey, model, parts)
    } else {
      const model = Deno.env.get('LLM_MODEL') ?? 'meta-llama/llama-3.1-8b-instruct'
      fields = await extractFields(apiKey, model, prompt + '\n\nDocument text:\n' + sliceText(text))
    }
    return json({ raw_text: text, fields, error: null })
  } catch (err) {
    return json({ raw_text: text, fields: null, error: `AI extraction failed: ${err}` })
  }
})

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
import { corsResponse, getCaller, json, withCors } from '../_shared/auth.ts'
import { customerPrompt, extractFields, extractFieldsText, sliceText, workOrderPrompt, type LlmContent } from '../_shared/extract_llm.ts'

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
- equipment_type: required equipment as stated (e.g. "53' Van", "Reefer", "Flatbed", "Power Only"). null if not stated.
- special_terms: short string (max 300 chars) with what a dispatcher must know: required equipment, temperature, tracking demands, unusual penalties. null if nothing notable.
- stops: ordered array of EVERY stop on the load (multi-stop loads have more than two). Each element: {"type": "pickup"|"delivery", "facility": company/location name or null, "address": street/city/state/zip or null, "datetime": "YYYY-MM-DDTHH:MM" or null (same rules as pickup_time), "reference": that stop's PU#/delivery#/PO or null}.
Two-digit years are 20xx. Use null for anything genuinely absent.`
}

// customerPrompt now lives in ../_shared/extract_llm.ts (shared with the
// customer-enrich batch backfill).

// LLM plumbing (callLlm / extractFields / parseFields / sliceText) lives in
// ../_shared/extract_llm.ts so trux-inbox's work-order path shares one brain.

Deno.serve(withCors(async (req) => {
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
  // mode=customer extracts the broker's company profile (Customers quick-add);
  // mode=work_order extracts a shop maintenance work order (Maintenance add).
  const mode = form.get('mode')
  const prompt = mode === 'customer' ? customerPrompt(carrier)
    : mode === 'work_order' ? workOrderPrompt()
    : extractionPrompt(carrier)

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
      // Text path prefers the free NAS model; the vision branch above stays cloud.
      fields = await extractFieldsText(apiKey, model, prompt + '\n\nDocument text:\n' + sliceText(text))
    }
    return json({ raw_text: text, fields, error: null })
  } catch (err) {
    return json({ raw_text: text, fields: null, error: `AI extraction failed: ${err}` })
  }
}))

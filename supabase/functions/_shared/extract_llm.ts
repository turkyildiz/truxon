// Shared LLM document-extraction helpers, used by extract-pdf (manual uploads)
// and trux-inbox (forwarded work-order emails). One extraction brain, one
// prompt library. OpenRouter/Groq-compatible chat-completions; env:
// LLM_API_KEY, optional LLM_BASE_URL, LLM_MODEL (text), LLM_VISION_MODEL.

export type LlmContent = string | Array<{ type: string; text?: string; image_url?: { url: string } }>

const TEXT_HEAD = 7000
const TEXT_TAIL = 4000

/** Keep the start AND end of a long document (totals hide near signatures). */
export function sliceText(text: string): string {
  if (text.length <= TEXT_HEAD + TEXT_TAIL + 100) return text
  return text.slice(0, TEXT_HEAD) + '\n...[middle of document omitted]...\n' + text.slice(-TEXT_TAIL)
}

export async function callLlm(apiKey: string, model: string, content: LlmContent): Promise<string> {
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
      if (attempt < 3) continue
      throw new Error(`LLM API unreachable: ${err}`)
    }
    if (resp.ok) {
      const data = await resp.json()
      return data.choices[0].message.content.trim()
    }
    await resp.body?.cancel()
    if (resp.status === 400 && jsonMode) {
      jsonMode = false
      continue
    }
    if ((resp.status === 429 || resp.status >= 500) && attempt < 3) {
      const retryAfter = Number(resp.headers.get('retry-after'))
      await new Promise((r) => setTimeout(r, Math.min(retryAfter > 0 ? retryAfter * 1000 : attempt * 4000, 15000)))
      continue
    }
    throw new Error(`LLM API returned ${resp.status}`)
  }
}

export function parseFields(content: string): Record<string, unknown> {
  let c = content
  if (c.startsWith('```')) c = c.replace(/^```(json)?/, '').replace(/```$/, '').trim()
  const start = c.indexOf('{')
  const end = c.lastIndexOf('}')
  if (start >= 0 && end > start) c = c.slice(start, end + 1)
  return JSON.parse(c)
}

/** Call the model, and if the reply isn't parseable JSON retry once with a
 * sharper instruction before giving up. */
export async function extractFields(apiKey: string, model: string, content: LlmContent): Promise<Record<string, unknown>> {
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

/** base64-encode bytes in chunks (avoids call-stack blowups on large images). */
export function toBase64(bytes: Uint8Array): string {
  let binary = ''
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  }
  return btoa(binary)
}

// ---------- work-order (maintenance) extraction ----------

/** Prompt for a shop's maintenance work order / repair invoice. The keys line up
 * 1:1 with create_work_order_draft's expected JSON so the pipeline stays typed. */
export function workOrderPrompt(): string {
  return `You extract structured data from a truck/trailer MAINTENANCE work order or repair shop invoice.
Respond with ONLY a JSON object (no markdown fences) with these keys:
- unit_number: the fleet unit number of the truck or trailer the work was done on — labels like "Unit", "Unit #", "Truck", "Truck #", "Vehicle", "Tractor", "Trailer #". The company's own equipment number, NOT the VIN or license plate. null if none.
- vin: the vehicle VIN if shown. null if none.
- service_type: the single closest category from EXACTLY this list — pm_service, oil_lube, tires, brakes, engine, drivetrain, electrical, cooling, aftertreatment, dot_inspection, bodywork, roadside, other. Use "pm_service" for a scheduled preventive/PM service, "dot_inspection" for an annual DOT inspection, "oil_lube" for oil/lube/filters, "aftertreatment" for DEF/DPF/emissions. Default "other" if unclear.
- description: a concise summary (max 300 chars) of the work performed / parts replaced.
- cost: the TOTAL amount of the invoice in dollars as a plain number — labels like "Total", "Grand Total", "Amount Due", "Balance Due", "Invoice Total". Not a line item. null if none.
- odometer: the odometer / mileage reading if shown, as a plain number. null if none.
- date: the service or invoice date as "YYYY-MM-DD". Two-digit years are 20xx. null if none.
- vendor: the repair shop / vendor business name that performed the work and issued this sheet. null if none.
- invoice_ref: the shop's own invoice number or work-order number as a string. null if none.
Use null for anything genuinely absent. Do not invent a unit number.`
}

export interface WorkOrderImage {
  bytes: Uint8Array
  mime: string
}

/** Extract work-order fields from a text layer and/or page/photo images. */
export async function extractWorkOrder(
  apiKey: string,
  input: { text?: string; images?: WorkOrderImage[] },
): Promise<Record<string, unknown>> {
  const prompt = workOrderPrompt()
  if (input.images && input.images.length > 0) {
    const model = Deno.env.get('LLM_VISION_MODEL') ?? 'meta-llama/llama-4-scout-17b-16e-instruct'
    const parts: LlmContent = [{ type: 'text', text: prompt + '\n\nThe work-order document follows as images.' }]
    for (const img of input.images) {
      parts.push({ type: 'image_url', image_url: { url: `data:${img.mime || 'image/jpeg'};base64,${toBase64(img.bytes)}` } })
    }
    return extractFields(apiKey, model, parts)
  }
  const model = Deno.env.get('LLM_MODEL') ?? 'meta-llama/llama-3.1-8b-instruct'
  return extractFields(apiKey, model, prompt + '\n\nDocument text:\n' + sliceText(input.text ?? ''))
}

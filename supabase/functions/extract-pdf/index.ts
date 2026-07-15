// AI-assisted extraction of load details from rate confirmation PDFs.
// Pipeline: unpdf pulls the text, an OpenRouter/Groq-compatible LLM
// structures it. Without LLM_API_KEY the raw text is still returned so
// the dispatcher can copy/paste.

import { extractText, getDocumentProxy } from 'npm:unpdf@0.12.1'
import { corsResponse, getCaller, json } from '../_shared/auth.ts'

const EXTRACTION_PROMPT = `You extract structured data from trucking rate confirmation documents.
Given the document text, respond with ONLY a JSON object (no markdown fences) with these keys:
- customer_name: the broker or customer company name issuing the load
- pickup_address: full pickup address
- pickup_time: pickup date/time in ISO 8601 format (null if not found)
- delivery_address: full delivery address
- delivery_time: delivery date/time in ISO 8601 format (null if not found)
- rate: total rate in dollars as a number (no currency symbol)
- special_terms: any special instructions or terms, as a short string
Use null for anything not present in the document.

Document text:
`

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()

  const caller = await getCaller(req)
  if (caller instanceof Response) return caller
  if (!['admin', 'dispatcher'].includes(caller.role)) {
    return json({ error: 'Not enough permissions' }, 403)
  }

  const form = await req.formData()
  const file = form.get('file')
  if (!(file instanceof File)) return json({ error: 'Upload a PDF file as "file"' }, 422)
  if (file.size > 15 * 1024 * 1024) return json({ error: 'PDF too large (15 MB max)' }, 413)

  let text = ''
  try {
    const pdf = await getDocumentProxy(new Uint8Array(await file.arrayBuffer()))
    const extracted = await extractText(pdf, { mergePages: true })
    text = extracted.text
  } catch (err) {
    return json({ raw_text: '', fields: null, error: `Could not read PDF: ${err}` })
  }
  if (!text.trim()) {
    return json({ raw_text: '', fields: null, error: 'PDF contains no extractable text (scanned image?)' })
  }

  const apiKey = Deno.env.get('LLM_API_KEY')
  if (!apiKey) {
    return json({ raw_text: text, fields: null, error: 'No LLM API key configured — fill fields manually' })
  }

  try {
    const resp = await fetch(`${Deno.env.get('LLM_BASE_URL') ?? 'https://openrouter.ai/api/v1'}/chat/completions`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: Deno.env.get('LLM_MODEL') ?? 'meta-llama/llama-3.1-8b-instruct',
        messages: [{ role: 'user', content: EXTRACTION_PROMPT + text.slice(0, 12000) }],
        temperature: 0,
      }),
    })
    if (!resp.ok) throw new Error(`LLM API returned ${resp.status}`)
    const data = await resp.json()
    let content: string = data.choices[0].message.content.trim()
    if (content.startsWith('```')) content = content.replace(/^```(json)?/, '').replace(/```$/, '').trim()
    return json({ raw_text: text, fields: JSON.parse(content), error: null })
  } catch (err) {
    return json({ raw_text: text, fields: null, error: `AI extraction failed: ${err}` })
  }
})

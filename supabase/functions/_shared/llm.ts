/** Multi-provider chat completion adapters (xAI / OpenAI / Anthropic). */

export type ChatMessage = { role: 'system' | 'user' | 'assistant' | 'tool'; content: string; name?: string }

export type ToolDef = {
  name: string
  description: string
  parameters: Record<string, unknown>
}

export type ToolCall = { id: string; name: string; arguments: string }

export type CompleteResult = {
  content: string
  tool_calls: ToolCall[]
  provider: string
  model: string
  est_cents: number
}

function env(name: string, fallback = ''): string {
  return Deno.env.get(name) ?? fallback
}

export function pickProvider(): { provider: 'xai' | 'openai' | 'anthropic'; model: string; apiKey: string; baseUrl?: string } {
  // Cost preference: xAI Grok default → OpenAI → Anthropic
  if (env('XAI_API_KEY') || (env('LLM_API_KEY') && (env('LLM_BASE_URL').includes('x.ai') || !env('LLM_BASE_URL')))) {
    const key = env('XAI_API_KEY') || env('LLM_API_KEY')
    if (key) {
      return {
        provider: 'xai',
        model: env('LLM_MODEL', 'grok-4.5') || env('XAI_MODEL', 'grok-4.5'),
        apiKey: key,
        baseUrl: env('LLM_BASE_URL', 'https://api.x.ai/v1'),
      }
    }
  }
  if (env('OPENAI_API_KEY')) {
    return { provider: 'openai', model: env('OPENAI_MODEL', 'gpt-4o-mini'), apiKey: env('OPENAI_API_KEY'), baseUrl: 'https://api.openai.com/v1' }
  }
  if (env('ANTHROPIC_API_KEY')) {
    return { provider: 'anthropic', model: env('ANTHROPIC_MODEL', 'claude-sonnet-4-20250514'), apiKey: env('ANTHROPIC_API_KEY') }
  }
  // Last resort: OpenRouter-style LLM_* used by extract-pdf
  if (env('LLM_API_KEY')) {
    return {
      provider: 'openai',
      model: env('LLM_MODEL', 'gpt-4o-mini'),
      apiKey: env('LLM_API_KEY'),
      baseUrl: env('LLM_BASE_URL', 'https://openrouter.ai/api/v1'),
    }
  }
  throw new Error('No LLM API key configured (XAI_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY / LLM_API_KEY)')
}

export async function completeChat(opts: {
  messages: ChatMessage[]
  tools?: ToolDef[]
}): Promise<CompleteResult> {
  const p = pickProvider()
  if (p.provider === 'anthropic') {
    return completeAnthropic(p.apiKey, p.model, opts.messages, opts.tools)
  }
  return completeOpenAICompat(p.baseUrl!, p.apiKey, p.model, p.provider, opts.messages, opts.tools)
}

async function completeOpenAICompat(
  baseUrl: string,
  apiKey: string,
  model: string,
  provider: string,
  messages: ChatMessage[],
  tools?: ToolDef[],
): Promise<CompleteResult> {
  const body: Record<string, unknown> = {
    model,
    messages: messages.map((m) => ({ role: m.role === 'tool' ? 'assistant' : m.role, content: m.content })),
  }
  if (tools?.length) {
    body.tools = tools.map((t) => ({
      type: 'function',
      function: { name: t.name, description: t.description, parameters: t.parameters },
    }))
    body.tool_choice = 'auto'
  }

  const res = await fetch(`${baseUrl.replace(/\/$/, '')}/chat/completions`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  })
  if (!res.ok) {
    const t = await res.text()
    throw new Error(`${provider} error ${res.status}: ${t.slice(0, 400)}`)
  }
  const data = await res.json()
  const choice = data.choices?.[0]?.message ?? {}
  const tool_calls: ToolCall[] = (choice.tool_calls ?? []).map((tc: { id: string; function: { name: string; arguments: string } }) => ({
    id: tc.id,
    name: tc.function.name,
    arguments: tc.function.arguments,
  }))
  const usage = data.usage ?? {}
  const tokens = (usage.prompt_tokens ?? 0) + (usage.completion_tokens ?? 0)
  // Rough cost estimate: ~$0.50 / 1M tokens average → 0.05¢ per 1k tokens → use 1¢ min
  const est_cents = Math.max(1, Math.ceil(tokens / 2000))

  return {
    content: choice.content ?? '',
    tool_calls,
    provider,
    model,
    est_cents,
  }
}

async function completeAnthropic(
  apiKey: string,
  model: string,
  messages: ChatMessage[],
  tools?: ToolDef[],
): Promise<CompleteResult> {
  const system = messages.filter((m) => m.role === 'system').map((m) => m.content).join('\n')
  const rest = messages.filter((m) => m.role !== 'system').map((m) => ({
    role: m.role === 'assistant' ? 'assistant' : 'user',
    content: m.content,
  }))

  const body: Record<string, unknown> = {
    model,
    max_tokens: 2048,
    system: system || 'You are Trux, a trucking TMS assistant.',
    messages: rest,
  }
  if (tools?.length) {
    body.tools = tools.map((t) => ({
      name: t.name,
      description: t.description,
      input_schema: t.parameters,
    }))
  }

  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  })
  if (!res.ok) {
    const t = await res.text()
    throw new Error(`anthropic error ${res.status}: ${t.slice(0, 400)}`)
  }
  const data = await res.json()
  let content = ''
  const tool_calls: ToolCall[] = []
  for (const block of data.content ?? []) {
    if (block.type === 'text') content += block.text
    if (block.type === 'tool_use') {
      tool_calls.push({
        id: block.id,
        name: block.name,
        arguments: JSON.stringify(block.input ?? {}),
      })
    }
  }
  const tokens = (data.usage?.input_tokens ?? 0) + (data.usage?.output_tokens ?? 0)
  const est_cents = Math.max(1, Math.ceil(tokens / 1500))
  return { content, tool_calls, provider: 'anthropic', model, est_cents }
}

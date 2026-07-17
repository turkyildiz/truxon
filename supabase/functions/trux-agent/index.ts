// Trux conversational agent — tool proposals with confirm-before-write.
//
// POST {
//   session_id?: uuid,
//   message?: string,                 // user text
//   confirm_token?: string,           // execute a proposed action
//   reject_token?: string
// }

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json } from '../_shared/auth.ts'
import { completeChat, type ToolDef } from '../_shared/llm.ts'

const TOOLS: ToolDef[] = [
  {
    name: 'search_customers',
    description: 'Search customers by name',
    parameters: {
      type: 'object',
      properties: { q: { type: 'string' } },
      required: ['q'],
    },
  },
  {
    name: 'list_available_equipment',
    description: 'List available trucks and active drivers for assignment',
    parameters: { type: 'object', properties: {} },
  },
  {
    name: 'create_load',
    description: 'Create a new load (propose only — user must confirm)',
    parameters: {
      type: 'object',
      properties: {
        customer_id: { type: 'number' },
        pickup_address: { type: 'string' },
        delivery_address: { type: 'string' },
        pickup_time: { type: 'string' },
        delivery_time: { type: 'string' },
        rate: { type: 'number' },
        miles: { type: 'number' },
        reference_number: { type: 'string' },
        special_terms: { type: 'string' },
        notes: { type: 'string' },
      },
      required: ['customer_id', 'pickup_address', 'delivery_address'],
    },
  },
  {
    name: 'assign_resources',
    description: 'Assign driver and truck (and optional trailer) to a load',
    parameters: {
      type: 'object',
      properties: {
        load_id: { type: 'number' },
        driver_id: { type: 'number' },
        truck_id: { type: 'number' },
        trailer_id: { type: 'number' },
      },
      required: ['load_id', 'driver_id', 'truck_id'],
    },
  },
  {
    name: 'change_load_status',
    description: 'Move load one step in the workflow (staff)',
    parameters: {
      type: 'object',
      properties: {
        load_id: { type: 'number' },
        status: { type: 'string', enum: ['pending', 'assigned', 'in_transit', 'delivered', 'completed', 'billed'] },
      },
      required: ['load_id', 'status'],
    },
  },
]

const WRITE_TOOLS = new Set(['create_load', 'assign_resources', 'change_load_status'])

function admin() {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
}

function token() {
  return crypto.randomUUID().replace(/-/g, '') + crypto.randomUUID().replace(/-/g, '').slice(0, 16)
}

async function readTool(
  sb: ReturnType<typeof admin>,
  name: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  if (name === 'search_customers') {
    const q = String(args.q ?? '')
    const { data, error } = await sb.from('customers').select('id, company_name, contact_person, phone').ilike('company_name', `%${q}%`).limit(10)
    if (error) throw new Error(error.message)
    return data
  }
  if (name === 'list_available_equipment') {
    const [{ data: trucks }, { data: drivers }] = await Promise.all([
      sb.from('trucks').select('id, unit_number, status').eq('status', 'available').limit(50),
      sb.from('drivers').select('id, full_name, status, user_id').eq('status', 'active').limit(50),
    ])
    return { trucks, drivers }
  }
  throw new Error(`Unknown read tool ${name}`)
}

async function executeWrite(
  userClient: ReturnType<typeof createClient>,
  name: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  if (name === 'create_load') {
    const { data, error } = await userClient.from('loads').insert({
      customer_id: args.customer_id,
      pickup_address: args.pickup_address ?? '',
      delivery_address: args.delivery_address ?? '',
      pickup_time: args.pickup_time || null,
      delivery_time: args.delivery_time || null,
      rate: args.rate ?? 0,
      miles: args.miles ?? 0,
      reference_number: args.reference_number ?? '',
      special_terms: args.special_terms ?? '',
      notes: args.notes ?? '',
    }).select('id, load_number, status').single()
    if (error) throw new Error(error.message)
    return data
  }
  if (name === 'assign_resources') {
    const { data, error } = await userClient.from('loads').update({
      driver_id: args.driver_id,
      truck_id: args.truck_id,
      trailer_id: args.trailer_id ?? null,
    }).eq('id', args.load_id).select('id, load_number, status, driver_id, truck_id').single()
    if (error) throw new Error(error.message)
    // Best-effort push
    try {
      await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/notify`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ action: 'notify_load', load_id: args.load_id, type: 'assignment' }),
      })
    } catch { /* ignore */ }
    return data
  }
  if (name === 'change_load_status') {
    const { data, error } = await userClient.rpc('change_load_status', {
      p_load_id: args.load_id,
      p_status: args.status,
    })
    if (error) throw new Error(error.message)
    return data
  }
  throw new Error(`Unknown write tool ${name}`)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const caller = await getCaller(req)
  if (caller instanceof Response) return caller
  if (!['admin', 'dispatcher'].includes(caller.role)) {
    return json({ error: 'Trux agent is for admin/dispatcher only' }, 403)
  }

  const body = await req.json().catch(() => ({}))
  const svc = admin()
  const userClient = caller.client

  // Ensure session
  let sessionId = body.session_id as string | undefined
  if (!sessionId) {
    const { data, error } = await svc.from('trux_sessions').insert({
      user_id: caller.userId,
      title: 'Trux',
    }).select('id').single()
    if (error) return json({ error: error.message }, 400)
    sessionId = data.id
  } else {
    const { data: s } = await svc.from('trux_sessions').select('id, user_id').eq('id', sessionId).maybeSingle()
    if (!s || s.user_id !== caller.userId) return json({ error: 'Session not found' }, 404)
  }

  // Confirm path
  if (body.confirm_token) {
    const tok = String(body.confirm_token)
    const { data: action, error } = await svc.from('trux_actions').select('*').eq('confirmation_token', tok).maybeSingle()
    if (error || !action) return json({ error: 'Action not found' }, 404)
    if (action.user_id !== caller.userId) return json({ error: 'Forbidden' }, 403)
    if (action.status === 'executed') {
      return json({ session_id: sessionId, already_executed: true, result: action.result })
    }
    if (action.status === 'executing') {
      return json({ session_id: sessionId, in_progress: true })
    }
    if (action.status !== 'proposed' || new Date(action.expires_at) < new Date()) {
      await svc.from('trux_actions').update({ status: 'expired' }).eq('id', action.id)
      return json({ error: 'Action expired or not confirmable' }, 400)
    }

    // Claim
    const { data: claimed } = await svc.from('trux_actions')
      .update({ status: 'executing' })
      .eq('id', action.id)
      .eq('status', 'proposed')
      .select()
      .maybeSingle()
    if (!claimed) return json({ error: 'Could not claim action' }, 409)

    try {
      const result = await executeWrite(userClient, action.tool_name, action.args as Record<string, unknown>)
      await svc.from('trux_actions').update({
        status: 'executed',
        result,
        executed_at: new Date().toISOString(),
      }).eq('id', action.id)
      await svc.from('trux_messages').insert({
        session_id: sessionId,
        role: 'assistant',
        content: `Done: ${action.tool_name} completed successfully.`,
        meta: { action_id: action.id, result },
      })
      await svc.from('trux_agent_audit').insert({
        user_id: caller.userId,
        session_id: sessionId,
        tool_name: action.tool_name,
        args: action.args,
        status: 'executed',
      })
      return json({ session_id: sessionId, executed: true, tool: action.tool_name, result })
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      await svc.from('trux_actions').update({ status: 'failed', error: msg }).eq('id', action.id)
      await svc.from('trux_messages').insert({
        session_id: sessionId,
        role: 'assistant',
        content: `Failed: ${action.tool_name} — ${msg}`,
        meta: { action_id: action.id },
      })
      return json({ error: msg, failed: true }, 400)
    }
  }

  if (body.reject_token) {
    await svc.from('trux_actions')
      .update({ status: 'expired' })
      .eq('confirmation_token', String(body.reject_token))
      .eq('user_id', caller.userId)
      .eq('status', 'proposed')
    return json({ session_id: sessionId, rejected: true })
  }

  const message = String(body.message ?? '').trim()
  if (!message) return json({ error: 'message or confirm_token required' }, 422)

  await svc.from('trux_messages').insert({
    session_id: sessionId,
    role: 'user',
    content: message,
  })

  try {
    await svc.rpc('llm_reserve_spend', { p_provider: 'agent', p_cents: 2 })
  } catch {
    /* budget optional if RPC missing */
  }

  const { data: history } = await svc
    .from('trux_messages')
    .select('role, content')
    .eq('session_id', sessionId)
    .order('id', { ascending: true })
    .limit(40)

  const system = `You are Trux (also called TRUX), the AI dispatcher assistant for Truxon TMS.
You help create loads from rate sheets, assign truck numbers and drivers, and advance load status.
Today is ${new Date().toISOString().slice(0, 10)}.
Rules:
- ALWAYS call search_customers / list_available_equipment before inventing IDs.
- Never invent customer_id / driver_id / truck_id — use tool results only.
- Write tools (create_load, assign_resources, change_load_status) are proposed for user confirmation.
- Prefer available trucks and active drivers.
- Be concise and operational.`

  type Msg = { role: 'system' | 'user' | 'assistant' | 'tool'; content: string }
  const messages: Msg[] = [
    { role: 'system', content: system },
    ...(history ?? []).map((h) => ({
      role: (h.role === 'tool' ? 'assistant' : h.role) as Msg['role'],
      content: h.content as string,
    })),
  ]

  const proposals: { token: string; tool: string; args: unknown; summary: string }[] = []
  let assistantText = ''
  let lastProvider = ''
  let lastModel = ''
  const deadline = Date.now() + 22_000
  const maxRounds = 3

  try {
    for (let round = 0; round < maxRounds && Date.now() < deadline; round++) {
      const completion = await completeChat({ messages, tools: TOOLS })
      lastProvider = completion.provider
      lastModel = completion.model
      try {
        await svc.rpc('llm_reserve_spend', { p_provider: completion.provider, p_cents: completion.est_cents })
      } catch { /* ignore */ }

      if (!completion.tool_calls.length) {
        assistantText = completion.content || assistantText
        break
      }

      const toolNotes: string[] = []
      let hadRead = false

      for (const tc of completion.tool_calls.slice(0, 6)) {
        let args: Record<string, unknown> = {}
        try {
          args = JSON.parse(tc.arguments || '{}')
        } catch {
          args = {}
        }

        if (!WRITE_TOOLS.has(tc.name)) {
          hadRead = true
          try {
            const result = await readTool(svc, tc.name, args)
            const snippet = JSON.stringify(result).slice(0, 1200)
            toolNotes.push(`${tc.name}: ${snippet}`)
            messages.push({ role: 'assistant', content: `Tool ${tc.name} args=${JSON.stringify(args)}` })
            messages.push({ role: 'user', content: `Tool result for ${tc.name}: ${snippet}` })
          } catch (e) {
            toolNotes.push(`${tc.name} failed: ${e instanceof Error ? e.message : e}`)
            messages.push({ role: 'user', content: `Tool ${tc.name} failed: ${e instanceof Error ? e.message : e}` })
          }
          continue
        }

        const tok = token()
        await svc.from('trux_actions').insert({
          session_id: sessionId,
          user_id: caller.userId,
          tool_name: tc.name,
          args,
          status: 'proposed',
          confirmation_token: tok,
          expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
        })
        proposals.push({
          token: tok,
          tool: tc.name,
          args,
          summary: `${tc.name}(${JSON.stringify(args).slice(0, 200)})`,
        })
      }

      if (proposals.length) {
        assistantText = completion.content || 'I prepared actions for your confirmation:'
        break
      }

      // Only reads — loop once more so the model can propose writes with real IDs
      if (hadRead) {
        messages.push({
          role: 'user',
          content: 'Using the tool results above, propose the next write actions if needed, or answer the user.',
        })
        if (toolNotes.length) {
          assistantText = (completion.content || '') + '\n' + toolNotes.map((n) => `(${n.slice(0, 400)})`).join('\n')
        }
        continue
      }

      assistantText = completion.content || assistantText
      break
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    return json({ error: msg }, 502)
  }

  if (proposals.length) {
    assistantText += '\n\n' + proposals.map((p, i) => `${i + 1}. ${p.summary}`).join('\n')
    assistantText += '\n\nConfirm each card to apply, or reject to cancel.'
  }
  if (!assistantText.trim()) {
    assistantText = 'I could not complete that request. Try rephrasing or check LLM API keys.'
  }

  await svc.from('trux_messages').insert({
    session_id: sessionId,
    role: 'assistant',
    content: assistantText,
    meta: { proposals, provider: lastProvider, model: lastModel },
  })

  return json({
    session_id: sessionId,
    reply: assistantText,
    proposals,
    provider: lastProvider,
    model: lastModel,
  })
})

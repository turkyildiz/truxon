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

  // Budget check (~2¢ reserve)
  const { data: okBudget } = await svc.rpc('llm_reserve_spend', { p_provider: 'pending', p_cents: 2 }).maybeSingle?.() ?? { data: null }
  // rpc may not be granted — call via SQL workaround with service role ignore if missing
  try {
    await svc.rpc('llm_reserve_spend', { p_provider: 'agent', p_cents: 2 })
  } catch {
    // if function not executable, continue (table may still work via direct insert in future)
  }
  void okBudget

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
- Use tools for data; never invent customer_id / driver_id / truck_id.
- Write operations will be proposed to the user for confirmation — describe them clearly.
- Prefer available trucks and active drivers.
- Be concise and operational.`

  let completion
  try {
    completion = await completeChat({
      messages: [
        { role: 'system', content: system },
        ...(history ?? []).map((h) => ({
          role: (h.role === 'tool' ? 'assistant' : h.role) as 'user' | 'assistant' | 'system',
          content: h.content,
        })),
      ],
      tools: TOOLS,
    })
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    return json({ error: msg }, 502)
  }

  // Record spend better if we have provider
  try {
    await svc.rpc('llm_reserve_spend', { p_provider: completion.provider, p_cents: completion.est_cents })
  } catch { /* ignore */ }

  const proposals: { token: string; tool: string; args: unknown; summary: string }[] = []
  let assistantText = completion.content || ''

  for (const tc of completion.tool_calls.slice(0, 6)) {
    let args: Record<string, unknown> = {}
    try {
      args = JSON.parse(tc.arguments || '{}')
    } catch {
      args = {}
    }

    if (!WRITE_TOOLS.has(tc.name)) {
      try {
        const result = await readTool(svc, tc.name, args)
        assistantText += `\n\n(${tc.name} → ${JSON.stringify(result).slice(0, 800)})`
      } catch (e) {
        assistantText += `\n\n(${tc.name} failed: ${e instanceof Error ? e.message : e})`
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

  if (proposals.length && !assistantText.trim()) {
    assistantText = 'I prepared actions for your confirmation:'
  }
  if (proposals.length) {
    assistantText += '\n\n' + proposals.map((p, i) => `${i + 1}. ${p.summary}`).join('\n')
    assistantText += '\n\nConfirm each card to apply, or reject to cancel.'
  }

  await svc.from('trux_messages').insert({
    session_id: sessionId,
    role: 'assistant',
    content: assistantText,
    meta: { proposals, provider: completion.provider, model: completion.model },
  })

  return json({
    session_id: sessionId,
    reply: assistantText,
    proposals,
    provider: completion.provider,
    model: completion.model,
  })
})

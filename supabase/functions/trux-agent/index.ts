// Trux — Truxon's operating agent. One agent, role-scoped tools, every tool
// runs as the calling user so RLS + RPC guards are the real permission layer.
// Writes are proposed with confirm-before-execute tokens.
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

type Sb = ReturnType<typeof createClient>

const ALL_TOOLS: Record<string, ToolDef> = {
  search_customers: {
    name: 'search_customers',
    description: 'Search customers by name',
    parameters: { type: 'object', properties: { q: { type: 'string' } }, required: ['q'] },
  },
  search_loads: {
    name: 'search_loads',
    description: 'Search loads by load number, broker reference, or address fragment. Empty q lists the most recent loads.',
    parameters: { type: 'object', properties: { q: { type: 'string' } } },
  },
  list_available_equipment: {
    name: 'list_available_equipment',
    description: 'List available trucks and active drivers for assignment',
    parameters: { type: 'object', properties: {} },
  },
  dashboard_recap: {
    name: 'dashboard_recap',
    description:
      'Company recap: this week revenue/miles/loads/rate-per-mile with comparisons to last week (to-date) and the same week last year, load status counts, top customers (90d), driver performance (30d), fleet availability.',
    parameters: { type: 'object', properties: {} },
  },
  weekly_report: {
    name: 'weekly_report',
    description: 'Weekly accounting report (totals plus per-driver pay and per-truck revenue) for the week containing the given date. Defaults to the current week.',
    parameters: { type: 'object', properties: { week_of: { type: 'string', description: 'YYYY-MM-DD' } } },
  },
  list_equipment: {
    name: 'list_equipment',
    description: 'List all trucks and trailers with their status',
    parameters: { type: 'object', properties: {} },
  },
  recent_maintenance: {
    name: 'recent_maintenance',
    description: 'List the most recent maintenance records',
    parameters: { type: 'object', properties: {} },
  },
  my_loads: {
    name: 'my_loads',
    description: 'List the loads assigned to me (the calling driver)',
    parameters: { type: 'object', properties: {} },
  },
  my_load_detail: {
    name: 'my_load_detail',
    description: 'Full detail for one of my loads',
    parameters: { type: 'object', properties: { load_id: { type: 'number' } }, required: ['load_id'] },
  },
  create_load: {
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
  assign_resources: {
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
  change_load_status: {
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
  update_my_load_status: {
    name: 'update_my_load_status',
    description: 'Update the status of one of my loads (driver; propose only — user must confirm)',
    parameters: {
      type: 'object',
      properties: {
        load_id: { type: 'number' },
        status: { type: 'string', enum: ['in_transit', 'delivered'] },
      },
      required: ['load_id', 'status'],
    },
  },
}

const WRITE_TOOLS = new Set(['create_load', 'assign_resources', 'change_load_status', 'update_my_load_status'])

/** Tool result JSON is clipped before going back to the model; report tools need more room. */
const SNIPPET_LIMITS: Record<string, number> = {
  dashboard_recap: 4000,
  weekly_report: 4000,
  my_loads: 2500,
  my_load_detail: 2500,
}

function toolsForRole(role: string): ToolDef[] {
  const names: string[] = (() => {
    switch (role) {
      case 'admin':
      case 'dispatcher':
        return [
          'search_customers', 'search_loads', 'list_available_equipment', 'dashboard_recap', 'weekly_report',
          'list_equipment', 'recent_maintenance', 'create_load', 'assign_resources', 'change_load_status',
        ]
      case 'accountant':
        return ['search_customers', 'search_loads', 'dashboard_recap', 'weekly_report']
      case 'driver':
        return ['my_loads', 'my_load_detail', 'update_my_load_status']
      case 'maintenance':
        return ['list_equipment', 'recent_maintenance']
      default:
        return []
    }
  })()
  return names.map((n) => ALL_TOOLS[n])
}

function roleGuidance(role: string): string {
  switch (role) {
    case 'admin':
    case 'dispatcher':
      return `You can search customers/loads, check equipment, give company recaps and weekly reports, and propose dispatch actions (create load, assign driver/truck, advance status).
- ALWAYS call search_customers / list_available_equipment before using IDs — never invent customer_id / driver_id / truck_id.
- For "how are we doing" questions, call dashboard_recap and narrate the numbers plainly, including the vs-last-week and vs-last-year comparisons when present.`
    case 'accountant':
      return `You can give company recaps, weekly accounting reports (per-driver pay, per-truck revenue), and search customers and loads. You cannot modify anything.`
    case 'driver':
      return `You talk to a driver. You can list their assigned loads, show load details (addresses, times, references), and propose status updates (in transit / delivered) for their confirmation. You only ever see this driver's own loads.`
    case 'maintenance':
      return `You can list trucks/trailers with status and recent maintenance records. You cannot modify anything.`
    default:
      return 'You have no tools for this role; answer questions about how to use Truxon.'
  }
}

function admin() {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
}

function token() {
  return crypto.randomUUID().replace(/-/g, '') + crypto.randomUUID().replace(/-/g, '').slice(0, 16)
}

/** All reads run as the calling user — RLS and RPC role guards enforce access. */
async function readTool(user: Sb, name: string, args: Record<string, unknown>): Promise<unknown> {
  if (name === 'search_customers') {
    const q = String(args.q ?? '')
    const { data, error } = await user.from('customers').select('id, company_name, contact_person, phone').ilike('company_name', `%${q}%`).limit(10)
    if (error) throw new Error(error.message)
    return data
  }
  if (name === 'search_loads') {
    // strip PostgREST or() metacharacters from the search term
    const q = String(args.q ?? '').replace(/[,()]/g, ' ').trim()
    let query = user.from('loads')
      .select('id, load_number, reference_number, status, pickup_address, delivery_address, pickup_time, rate, miles, customers(company_name)')
      .order('created_at', { ascending: false })
      .limit(10)
    if (q) query = query.or(`load_number.ilike.%${q}%,reference_number.ilike.%${q}%,pickup_address.ilike.%${q}%,delivery_address.ilike.%${q}%`)
    const { data, error } = await query
    if (error) throw new Error(error.message)
    return data
  }
  if (name === 'list_available_equipment') {
    const [trucks, drivers] = await Promise.all([
      user.from('trucks').select('id, unit_number, status').eq('status', 'available').limit(50),
      user.from('drivers').select('id, full_name, status').eq('status', 'active').limit(50),
    ])
    if (trucks.error) throw new Error(trucks.error.message)
    if (drivers.error) throw new Error(drivers.error.message)
    return { trucks: trucks.data, drivers: drivers.data }
  }
  if (name === 'dashboard_recap') {
    const { data, error } = await user.rpc('dashboard_summary')
    if (error) throw new Error(error.message)
    const d = data as Record<string, unknown>
    return {
      this_week: {
        revenue: d.week_revenue, miles: d.week_miles, loads: d.week_loads, avg_rate_per_mile: d.week_avg_rate_per_mile,
      },
      last_week_to_date: d.prev_week,
      same_week_last_year_to_date: d.prev_year_week,
      status_counts: d.status_counts,
      available_trucks: d.available_trucks,
      active_drivers: d.active_drivers,
      top_customers_90d: d.top_customers,
      driver_performance_30d: d.driver_perf,
      licenses_expiring_30d: (d.expiring_licenses as unknown[])?.length ?? 0,
    }
  }
  if (name === 'weekly_report') {
    const params = args.week_of ? { p_week_of: String(args.week_of) } : {}
    const { data, error } = await user.rpc('weekly_report', params)
    if (error) throw new Error(error.message)
    const d = data as Record<string, unknown>
    type Row = Record<string, unknown>
    return {
      week: `${d.week_start} → ${d.week_end}`,
      totals: d.totals,
      by_driver: (d.by_driver as Row[])?.map((r) => ({ name: r.name, loads: r.loads, miles: r.miles, empty_miles: r.empty_miles, revenue: r.revenue, driver_pay: r.driver_pay })),
      by_truck: (d.by_truck as Row[])?.map((r) => ({ name: r.name, loads: r.loads, revenue: r.revenue })),
    }
  }
  if (name === 'list_equipment') {
    const [trucks, trailers] = await Promise.all([
      user.from('trucks').select('id, unit_number, status, plate_number').limit(60),
      user.from('trailers').select('id, unit_number, status, plate_number').limit(60),
    ])
    if (trucks.error) throw new Error(trucks.error.message)
    if (trailers.error) throw new Error(trailers.error.message)
    return { trucks: trucks.data, trailers: trailers.data }
  }
  if (name === 'recent_maintenance') {
    const { data, error } = await user.from('maintenance_records')
      .select('id, equipment_type, date_completed, description, cost, technician_shop')
      .order('date_completed', { ascending: false, nullsFirst: false })
      .limit(10)
    if (error) throw new Error(error.message)
    return data
  }
  if (name === 'my_loads') {
    const { data, error } = await user.rpc('driver_my_loads')
    if (error) throw new Error(error.message)
    return data
  }
  if (name === 'my_load_detail') {
    const { data, error } = await user.rpc('driver_get_load', { p_load_id: args.load_id })
    if (error) throw new Error(error.message)
    return data
  }
  throw new Error(`Unknown read tool ${name}`)
}

async function executeWrite(userClient: Sb, name: string, args: Record<string, unknown>): Promise<unknown> {
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
  if (name === 'update_my_load_status') {
    const { data, error } = await userClient.rpc('driver_change_load_status', {
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
  const tools = toolsForRole(caller.role)
  if (!tools.length) {
    return json({ error: 'Trux has no tools for your role yet' }, 403)
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

  const system = `You are Trux, the operating assistant inside Truxon TMS for Aida Logistics.
You are talking to a signed-in ${caller.role}. Today is ${new Date().toISOString().slice(0, 10)}.
${roleGuidance(caller.role)}
General rules:
- Use tools for facts; never invent numbers or IDs.
- Write tools are only ever PROPOSED — the user confirms them in the app.
- Money in USD, be concise and operational, plain sentences over jargon.`

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
      const completion = await completeChat({ messages, tools })
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

        // The model may only use tools granted to this role.
        if (!tools.some((t) => t.name === tc.name)) {
          messages.push({ role: 'user', content: `Tool ${tc.name} is not available to this user.` })
          continue
        }

        if (!WRITE_TOOLS.has(tc.name)) {
          hadRead = true
          try {
            const result = await readTool(userClient, tc.name, args)
            const snippet = JSON.stringify(result).slice(0, SNIPPET_LIMITS[tc.name] ?? 1200)
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

      // Only reads — loop once more so the model can answer (or propose writes) with real data
      if (hadRead) {
        messages.push({
          role: 'user',
          content: 'Using the tool results above, answer the user in plain language (or propose the next write actions if that is what they asked for).',
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

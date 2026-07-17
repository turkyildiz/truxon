// Trux agent core — shared by every Trux door (in-app chat, email inbox).
// Tools are role-scoped and run as the acting user (their JWT client), so RLS
// and RPC guards enforce permissions regardless of which door invoked Trux.
//
// Two execution modes:
//   propose  (chat)  — write tools become trux_actions rows awaiting a
//                      confirm click; nothing is executed here.
//   auto     (email) — write tools execute immediately (the door has already
//                      verified the sender); results feed back into the loop
//                      so multi-step requests (create load → assign) work.

import type { createClient } from 'jsr:@supabase/supabase-js@2'
import { completeChat, type ToolDef } from './llm.ts'

export type Sb = ReturnType<typeof createClient>

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
  query_data: {
    name: 'query_data',
    description: `Answer ANY analytical question by writing one read-only SQL SELECT (Postgres). It runs AS the signed-in user — row-level security decides what they can see. Max 200 rows; keep it to one statement, no semicolons.
Schema: loads(id, load_number, reference_number, customer_id, driver_id, truck_id, trailer_id, status[pending|assigned|in_transit|delivered|completed|billed], pickup_address, pickup_time, delivery_address, delivery_time, rate, miles, empty_miles, equipment_type, invoice_id, created_at) · customers(id, company_name, phone, email, billing_address, payment_terms, is_active) · drivers(id, full_name, status, pay_per_mile, empty_miles_paid, pay_per_empty_mile, license_expiration, hire_date) · trucks/trailers(id, unit_number, status, plate_number, monthly_cost) · invoices(id, invoice_number, customer_id, invoice_date, total, status) · maintenance_records(id, equipment_type, truck_id, trailer_id, date_completed, description, cost) · load_stops(load_id, stop_type, seq, facility, address, stop_time).
Revenue convention: completed/billed loads, delivery_time as the date. Example: monthly revenue = select to_char(date_trunc('month', delivery_time),'YYYY-MM') m, sum(rate) rev, sum(miles) mi, count(*) loads from loads where status in ('completed','billed') group by 1 order by 1.
RULES: rate-per-mile and similar averages must be WEIGHTED — sum(rate)/nullif(sum(miles),0) — never avg(rate/miles). Always select the supporting figures (counts, sums) alongside any ratio and show them in your answer so the user can verify. If a result looks implausible (e.g. rate/mile far outside $1.50-$6 for linehaul), double-check with a second query before answering.`,
    parameters: { type: 'object', properties: { sql: { type: 'string' } }, required: ['sql'] },
  },
  system_status: {
    name: 'system_status',
    description: 'Current Truxon system health: watchdog check states (email pipeline, edge functions, AI provider, Microsoft Graph auth)',
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
    description: 'Create a new load',
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
        pickup_number: { type: 'string' },
        delivery_number: { type: 'string' },
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
    description: 'Update the status of one of my loads (driver)',
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

export const WRITE_TOOLS = new Set(['create_load', 'assign_resources', 'change_load_status', 'update_my_load_status'])

/** Tool result JSON is clipped before going back to the model; report tools need more room. */
const SNIPPET_LIMITS: Record<string, number> = {
  dashboard_recap: 6000,
  weekly_report: 4000,
  query_data: 5000,
  my_loads: 2500,
  my_load_detail: 2500,
}

export function toolsForRole(role: string): ToolDef[] {
  const names: string[] = (() => {
    switch (role) {
      case 'admin':
        return [
          'search_customers', 'search_loads', 'list_available_equipment', 'dashboard_recap', 'weekly_report',
          'list_equipment', 'recent_maintenance', 'create_load', 'assign_resources', 'change_load_status',
          'system_status', 'query_data',
        ]
      case 'dispatcher':
        return [
          'search_customers', 'search_loads', 'list_available_equipment', 'dashboard_recap', 'weekly_report',
          'list_equipment', 'recent_maintenance', 'create_load', 'assign_resources', 'change_load_status',
          'query_data',
        ]
      case 'accountant':
        return ['search_customers', 'search_loads', 'dashboard_recap', 'weekly_report', 'query_data']
      case 'driver':
        return ['my_loads', 'my_load_detail', 'update_my_load_status', 'query_data']
      case 'maintenance':
        return ['list_equipment', 'recent_maintenance', 'query_data']
      default:
        return []
    }
  })()
  return names.map((n) => ALL_TOOLS[n])
}

export function roleGuidance(role: string): string {
  switch (role) {
    case 'admin':
    case 'dispatcher':
      return `You can search customers/loads, check equipment, give company recaps and weekly reports, and take dispatch actions (create load, assign driver/truck, advance status).
- ALWAYS call search_customers / list_available_equipment before using IDs — never invent customer_id / driver_id / truck_id.
- For "how are we doing" questions, call dashboard_recap and narrate the numbers plainly, including the vs-last-week and vs-last-year comparisons when present.`
    case 'accountant':
      return `You can give company recaps, weekly accounting reports (per-driver pay, per-truck revenue), and search customers and loads. You cannot modify anything.`
    case 'driver':
      return `You talk to a driver. You can list their assigned loads, show load details (addresses, times, references), and update status (in transit / delivered). You only ever see this driver's own loads.`
    case 'maintenance':
      return `You can list trucks/trailers with status and recent maintenance records. You cannot modify anything.`
    default:
      return 'You have no tools for this role; answer questions about how to use Truxon.'
  }
}

/** All reads run as the acting user — RLS and RPC role guards enforce access. */
export async function readTool(user: Sb, name: string, args: Record<string, unknown>): Promise<unknown> {
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
      trend_last_12_weeks: d.trend_weekly,
      trend_last_12_months: d.trend_monthly,
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
  if (name === 'query_data') {
    const { data, error } = await user.rpc('trux_query', { p_sql: String(args.sql ?? '') })
    if (error) throw new Error(error.message)
    return data
  }
  if (name === 'system_status') {
    // RLS limits this table to admins; the tool is only offered to admins.
    const { data, error } = await user.from('watchdog_state')
      .select('check_name, status, detail, last_change, updated_at')
      .order('check_name')
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

export async function executeWrite(userClient: Sb, name: string, args: Record<string, unknown>): Promise<unknown> {
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
      pickup_number: args.pickup_number ?? '',
      delivery_number: args.delivery_number ?? '',
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

export interface TruxRunOpts {
  svc: Sb
  userClient: Sb
  userId: string
  role: string
  sessionId: string
  message: string
  /** 'propose' (chat confirm cards) or 'auto' (verified doors: execute now). */
  mode: 'propose' | 'auto'
  /** Extra system prompt context, e.g. the email channel preamble. */
  channelNote?: string
  /** Reply used when the model produces nothing (door-appropriate wording). */
  fallbackReply?: string
  deadlineMs?: number
}

export interface TruxRunResult {
  reply: string
  proposals: { token: string; tool: string; args: unknown; summary: string }[]
  executed: { tool: string; args: unknown; result?: unknown; error?: string }[]
  provider: string
  model: string
}

function token() {
  return crypto.randomUUID().replace(/-/g, '') + crypto.randomUUID().replace(/-/g, '').slice(0, 16)
}

/** One Trux turn: history in trux_messages, tool loop, mode-dependent writes. */
export async function runTrux(opts: TruxRunOpts): Promise<TruxRunResult> {
  const { svc, userClient, userId, role, sessionId, message, mode } = opts
  const tools = toolsForRole(role)

  await svc.from('trux_messages').insert({ session_id: sessionId, role: 'user', content: message })

  try {
    await svc.rpc('llm_reserve_spend', { p_provider: 'agent', p_cents: 2 })
  } catch { /* budget optional */ }

  // Newest 12 turns only, older ones clipped hard — replaying a long email
  // thread (each turn embedding a 6k-char document) burns the provider's
  // tokens-per-minute budget. The final entry is the current message: keep it
  // intact so the attached document survives.
  const { data: historyDesc } = await svc
    .from('trux_messages')
    .select('role, content')
    .eq('session_id', sessionId)
    .order('id', { ascending: false })
    .limit(12)
  const history = (historyDesc ?? []).reverse().map((h, i, arr) => ({
    role: h.role,
    content: (h.content as string).slice(0, i === arr.length - 1 ? 9000 : 1500),
  }))

  const system = `You are Trux, the operating assistant inside Truxon TMS for Aida Logistics.
You are acting for a verified ${role}. Today is ${new Date().toISOString().slice(0, 10)}.
${opts.channelNote ?? ''}
${roleGuidance(role)}
General rules:
- Use tools for facts; never invent numbers or IDs.
${mode === 'propose'
    ? '- Write tools are only ever PROPOSED — the user confirms them in the app.'
    : '- Write tools execute immediately; report exactly what you did. If anything is ambiguous (e.g. a name matching several people, no matching customer), do NOT guess — ask a clarifying question instead.'}
- Money in USD, be concise and operational, plain sentences over jargon.`

  type Msg = { role: 'system' | 'user' | 'assistant' | 'tool'; content: string }
  const messages: Msg[] = [
    { role: 'system', content: system },
    ...(history ?? []).map((h) => ({
      role: (h.role === 'tool' ? 'assistant' : h.role) as Msg['role'],
      content: h.content as string,
    })),
  ]

  const proposals: TruxRunResult['proposals'] = []
  const executed: TruxRunResult['executed'] = []
  let assistantText = ''
  let lastProvider = ''
  let lastModel = ''
  const deadline = Date.now() + (opts.deadlineMs ?? 22_000)
  const maxRounds = mode === 'auto' ? 5 : 3

  for (let round = 0; round < maxRounds && Date.now() < deadline; round++) {
    // Retry once: malformed tool calls (400) recover after a beat; 429s wait
    // exactly as long as the provider asks ("try again in 420ms" / "8.7s").
    let completion
    try {
      completion = await completeChat({ messages, tools })
    } catch (e) {
      const msg = String(e)
      let wait = 1_200
      // Rate limited (429) or provider overloaded (Anthropic 529) — back off.
      if (/\b(429|529)\b|overloaded|rate.?limit/i.test(msg)) {
        const m = msg.match(/try again in ([\d.]+)\s*(ms|s)/i)
        wait = m ? Math.ceil(parseFloat(m[1]) * (m[2].toLowerCase() === 'ms' ? 1 : 1000)) + 800 : 20_000
      }
      if (Date.now() + wait + 3_000 > deadline) throw e
      await new Promise((r) => setTimeout(r, wait))
      completion = await completeChat({ messages, tools })
    }
    lastProvider = completion.provider
    lastModel = completion.model
    try {
      await svc.rpc('llm_reserve_spend', { p_provider: completion.provider, p_cents: completion.est_cents })
    } catch { /* ignore */ }

    if (!completion.tool_calls.length) {
      if (!completion.content && !assistantText && round < maxRounds - 1) {
        // Model returned nothing at all — nudge once instead of giving up.
        messages.push({ role: 'user', content: 'Your last response was empty. Answer the user now, or call the appropriate tool.' })
        continue
      }
      assistantText = completion.content || assistantText
      break
    }

    let hadTool = false

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
        hadTool = true
        try {
          const result = await readTool(userClient, tc.name, args)
          const snippet = JSON.stringify(result).slice(0, SNIPPET_LIMITS[tc.name] ?? 1200)
          messages.push({ role: 'assistant', content: `Tool ${tc.name} args=${JSON.stringify(args)}` })
          messages.push({ role: 'user', content: `Tool result for ${tc.name}: ${snippet}` })
        } catch (e) {
          messages.push({ role: 'user', content: `Tool ${tc.name} failed: ${e instanceof Error ? e.message : e}` })
        }
        continue
      }

      // Write tool
      if (mode === 'propose') {
        const tok = token()
        await svc.from('trux_actions').insert({
          session_id: sessionId,
          user_id: userId,
          tool_name: tc.name,
          args,
          status: 'proposed',
          confirmation_token: tok,
          expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
        })
        proposals.push({ token: tok, tool: tc.name, args, summary: `${tc.name}(${JSON.stringify(args).slice(0, 200)})` })
        continue
      }

      // auto mode — execute now, feed the result back, keep looping
      hadTool = true
      try {
        const result = await executeWrite(userClient, tc.name, args)
        executed.push({ tool: tc.name, args, result })
        await svc.from('trux_actions').insert({
          session_id: sessionId,
          user_id: userId,
          tool_name: tc.name,
          args,
          status: 'executed',
          result,
          confirmation_token: token(),
          expires_at: new Date().toISOString(),
          executed_at: new Date().toISOString(),
        })
        await svc.from('trux_agent_audit').insert({
          user_id: userId,
          session_id: sessionId,
          tool_name: tc.name,
          args,
          status: 'executed',
        })
        messages.push({ role: 'assistant', content: `Tool ${tc.name} args=${JSON.stringify(args)}` })
        messages.push({ role: 'user', content: `Tool ${tc.name} EXECUTED. Result: ${JSON.stringify(result).slice(0, 800)}` })
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e)
        executed.push({ tool: tc.name, args, error: msg })
        await svc.from('trux_agent_audit').insert({
          user_id: userId,
          session_id: sessionId,
          tool_name: tc.name,
          args,
          status: 'failed',
        })
        messages.push({ role: 'user', content: `Tool ${tc.name} FAILED: ${msg}` })
      }
    }

    if (proposals.length) {
      assistantText = completion.content || 'I prepared actions for your confirmation:'
      break
    }

    if (hadTool) {
      messages.push({
        role: 'user',
        content: mode === 'auto'
          ? 'Continue: run the next needed tool, or if everything requested is done (or blocked), write the final summary of what was done including load numbers.'
          : 'Using the tool results above, answer the user in plain language (or propose the next write actions if that is what they asked for).',
      })
      assistantText = completion.content || assistantText
      continue
    }

    assistantText = completion.content || assistantText
    break
  }

  if (proposals.length) {
    assistantText += '\n\n' + proposals.map((p, i) => `${i + 1}. ${p.summary}`).join('\n')
    assistantText += '\n\nConfirm each card to apply, or reject to cancel.'
  }
  if (!assistantText.trim()) {
    assistantText = executed.length
      ? 'Done: ' + executed.map((e) => `${e.tool}${e.error ? ` FAILED (${e.error})` : ''}`).join(', ')
      : opts.fallbackReply ?? 'I could not complete that request. Try rephrasing or check LLM API keys.'
  }

  await svc.from('trux_messages').insert({
    session_id: sessionId,
    role: 'assistant',
    content: assistantText,
    meta: { proposals, executed, provider: lastProvider, model: lastModel },
  })

  return { reply: assistantText, proposals, executed, provider: lastProvider, model: lastModel }
}

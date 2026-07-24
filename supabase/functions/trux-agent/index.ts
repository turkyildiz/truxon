// Trux — in-app chat door. Agent core lives in _shared/truxcore.ts; this door
// runs in 'propose' mode: write tools become confirm cards, and the confirm /
// reject paths below execute or expire them.
//
// POST {
//   session_id?: uuid,
//   message?: string,                 // user text
//   confirm_token?: string,           // execute a proposed action
//   reject_token?: string
// }

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json, withCors } from '../_shared/auth.ts'
import { executeWrite, runTrux, toolsForRole } from '../_shared/truxcore.ts'

function admin() {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
}

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const caller = await getCaller(req)
  if (caller instanceof Response) return caller
  if (!toolsForRole(caller.role).length) {
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

  try {
    const run = await runTrux({
      svc,
      userClient,
      userId: caller.userId,
      role: caller.role,
      sessionId: sessionId!,
      message,
      mode: 'propose',
      // Report questions legitimately need several tool rounds; the in-app
      // spinner can wait, the gateway allows 150s idle.
      deadlineMs: 100_000,
      // Voice channels: the reply is spoken aloud, so it must sound like talk,
      // not a report. `radio` = fleet PTT to every truck; `spoken` = one person
      // on their tablet (a touch more room, but still brief and conversational).
      channelNote: body.radio === true
        ? 'RADIO MODE: your reply will be READ ALOUD over the fleet push-to-talk radio to all drivers. Answer in 1-3 short spoken sentences, plain conversational words — no markdown, no tables, no lists, round the numbers.'
        : body.spoken === true
        ? 'SPOKEN MODE: your reply is read aloud to one person on a tablet — no screen-reading of tables. Answer in a few short, natural spoken sentences, plain conversational words, no markdown, no lists, round the numbers. Lead with the answer; if there is a lot of detail, give the headline and the one or two figures that matter and offer to pull the rest up on screen — do not recite a long list aloud.'
        : undefined,
    })
    return json({
      session_id: sessionId,
      reply: run.reply,
      proposals: run.proposals,
      provider: run.provider,
      model: run.model,
    })
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    return json({ error: msg }, 502)
  }
}))

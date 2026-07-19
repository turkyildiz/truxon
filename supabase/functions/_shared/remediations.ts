// The self-heal registry — the ENUMERABLE hands of the watchdog.
//
// Safety model: the watchdog runs on an anon-key-reachable cron endpoint, so
// an attacker who can induce a failure must never be able to make it do
// something dangerous. Therefore every remediation here is:
//   1. code-defined (this file) — nothing the LLM or an email can invent;
//   2. DB-scoped and reversible — it captures before-state and can revert;
//   3. rate-limited — maxPerHour caps a flapping check's blast radius;
//   4. ledgered — every run writes watchdog_remediations with before/after.
//
// tier:
//   'auto'     — reversible + low-risk enough to run unattended (Tier 3);
//                applied, then verify() must pass or it is reverted.
//   'approval' — still allowlisted + reversible, but waits for a one-tap
//                human approval (Tier 2) before apply().
//
// What is deliberately NOT here: anything that deploys code, changes schema,
// edits business/financial rows, or touches secrets. Those require credentials
// this function does not (and must not) hold; they can only ever be surfaced
// as a proposal for a human — see the workstation responder (read-only) for
// diagnosis and the docs for the deploy path.

// deno-lint-ignore no-explicit-any
export type Svc = any

export interface Remediation {
  key: string
  tier: 'auto' | 'approval'
  maxPerHour: number
  /** Does this remediation address the given failing check? */
  appliesTo: (checkName: string, detail: string) => boolean
  /** Human-readable one-liner for alerts/approval prompts. */
  describe: (checkName: string, detail: string) => string
  /** Snapshot the state this action will change, for revert + audit. */
  snapshot: (svc: Svc) => Promise<Record<string, unknown>>
  /** Perform the fix. Throw to record failure. */
  apply: (svc: Svc, before: Record<string, unknown>) => Promise<string>
  /** Canary: true iff the fix took (re-checked after apply). */
  verify: (svc: Svc) => Promise<boolean>
  /** Undo apply() using the snapshot. Best-effort. */
  revert: (svc: Svc, before: Record<string, unknown>) => Promise<void>
}

const THROTTLE_ROW = { id: 1 }

export const REGISTRY: Remediation[] = [
  // The inbox poller claims a poll only if last_poll < now-30s. A crash or
  // clock skew can leave last_poll set in the FUTURE, wedging polling forever.
  // Resetting it to a poll-permitting position (now-90s) unblocks the next
  // cron tick. The canary confirms the throttle is now in that healthy window
  // — NOT that a poll already ran (that happens on a later cron tick and shows
  // up as inbox_poll_fresh recovering). If the poller itself is down, the
  // check stays red and escalates to a human alert, which is correct.
  {
    key: 'reset_inbox_poll_throttle',
    tier: 'auto',
    maxPerHour: 3,
    appliesTo: (name) => name === 'inbox_poll_fresh',
    describe: () => 'Reset the inbox-poll throttle to a poll-permitting state',
    async snapshot(svc) {
      const { data } = await svc.from('trux_inbox_state').select('last_poll').eq('id', 1).maybeSingle()
      return { last_poll: data?.last_poll ?? null }
    },
    async apply(svc) {
      const target = new Date(Date.now() - 90_000).toISOString()
      const { error } = await svc.from('trux_inbox_state').update({ last_poll: target }).match(THROTTLE_ROW)
      if (error) throw new Error(error.message)
      return 'throttle set to a poll-permitting position (now-90s)'
    },
    async verify(svc) {
      // Healthy window: past the 30s gate (so the next poll is allowed) but not
      // absurdly old or in the future.
      const { data } = await svc.from('trux_inbox_state').select('last_poll').eq('id', 1).maybeSingle()
      const t = data?.last_poll ? new Date(data.last_poll).getTime() : 0
      return t <= Date.now() - 30_000 && t >= Date.now() - 10 * 60_000
    },
    async revert(svc, before) {
      if (before.last_poll) {
        await svc.from('trux_inbox_state').update({ last_poll: before.last_poll }).match(THROTTLE_ROW)
      }
    },
  },

  // Log rows stuck in 'processing' (a poll died mid-message) never get retried
  // and never clear. Flipping stale ones to 'retry_pending' lets the poller
  // reclaim them. Reversible (revert restores 'processing').
  {
    key: 'requeue_stuck_processing',
    tier: 'auto',
    maxPerHour: 4,
    appliesTo: (name) => name === 'inbox_failures' || name === 'inbox_poll_fresh',
    describe: () => 'Requeue inbox messages stuck mid-processing for retry',
    async snapshot(svc) {
      const cutoff = new Date(Date.now() - 15 * 60000).toISOString()
      const { data } = await svc.from('trux_inbox_log')
        .select('graph_message_id').eq('status', 'processing').lt('created_at', cutoff).limit(25)
      return { ids: (data ?? []).map((r: { graph_message_id: string }) => r.graph_message_id) }
    },
    async apply(svc, before) {
      const ids = (before.ids as string[]) ?? []
      if (ids.length === 0) return 'no stuck rows'
      const { error } = await svc.from('trux_inbox_log')
        .update({ status: 'retry_pending' }).in('graph_message_id', ids)
      if (error) throw new Error(error.message)
      return `requeued ${ids.length} stuck message(s)`
    },
    async verify(svc) {
      const cutoff = new Date(Date.now() - 15 * 60000).toISOString()
      const { count } = await svc.from('trux_inbox_log')
        .select('graph_message_id', { count: 'exact', head: true })
        .eq('status', 'processing').lt('created_at', cutoff)
      return (count ?? 0) === 0
    },
    async revert(svc, before) {
      const ids = (before.ids as string[]) ?? []
      if (ids.length) await svc.from('trux_inbox_log').update({ status: 'processing' }).in('graph_message_id', ids)
    },
  },

  // Load-shedding: if the LLM daily budget is blown and the agent is erroring,
  // flip agent_enabled off so the app degrades cleanly to manual instead of
  // erroring on every request. Reversible, but human-approved — turning the
  // assistant off is a product decision, not silently automatic.
  {
    key: 'disable_agent_load_shed',
    tier: 'approval',
    maxPerHour: 2,
    appliesTo: (name) => name === 'llm_provider' || name === 'llm_budget',
    describe: () => 'Temporarily disable the Trux agent (degrade to manual) until the LLM issue clears',
    async snapshot(svc) {
      const { data } = await svc.from('companion_config').select('flags').eq('id', 1).maybeSingle()
      return { flags: data?.flags ?? {} }
    },
    async apply(svc, before) {
      const flags = { ...(before.flags as Record<string, unknown>), agent_enabled: false }
      const { error } = await svc.from('companion_config').update({ flags }).eq('id', 1)
      if (error) throw new Error(error.message)
      return 'agent_enabled set to false'
    },
    async verify(svc) {
      const { data } = await svc.from('companion_config').select('flags').eq('id', 1).maybeSingle()
      return data?.flags?.agent_enabled === false
    },
    async revert(svc, before) {
      await svc.from('companion_config').update({ flags: before.flags }).eq('id', 1)
    },
  },
]

/** Pick the first registry entry that addresses a failing check. */
export function remediationFor(checkName: string, detail: string): Remediation | undefined {
  return REGISTRY.find((r) => r.appliesTo(checkName, detail))
}

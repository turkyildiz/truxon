// deno test supabase/functions/_shared/truxcore.test.ts
//
// READINESS #194: the AI agent's per-role tool authorization. toolsForRole()
// decides which tools Forest exposes to a caller by role, and the agent runs
// those tools AS the user — so this list is a real authorization boundary. A
// driver who could reach create_load, assign_resources, or bank_balance THROUGH
// the agent would have an escalation the RLS layer never sees coming. This pins
// the tiering and guards against a mistyped tool name resolving to `undefined`.
import { assert } from 'jsr:@std/assert@1'
import { toolsForRole, WRITE_TOOLS } from './truxcore.ts'

const names = (role: string) => new Set(toolsForRole(role).map((t) => t.name))

Deno.test('an unknown or empty role gets no tools (fails closed)', () => {
  assert(toolsForRole('superuser').length === 0)
  assert(toolsForRole('').length === 0)
})

Deno.test('every role resolves to real tool defs — no undefined from a mistyped name', () => {
  for (const role of ['admin', 'dispatcher', 'accountant', 'driver', 'maintenance']) {
    for (const t of toolsForRole(role)) {
      assert(t && typeof t.name === 'string', `${role} exposes an undefined tool`)
    }
  }
})

Deno.test('a driver gets only own-load tools — no dispatch writes, finances, or roster', () => {
  const d = names('driver')
  for (const forbidden of ['create_load', 'assign_resources', 'change_load_status', 'bank_balance', 'system_status', 'search_customers', 'search_loads']) {
    assert(!d.has(forbidden), `driver must not reach ${forbidden}`)
  }
  assert(d.has('my_loads'))
  assert(d.has('update_my_load_status'))
})

Deno.test('an accountant sees finances but cannot dispatch (no write tools at all)', () => {
  const a = names('accountant')
  assert(a.has('bank_balance'))
  for (const w of WRITE_TOOLS) assert(!a.has(w), `accountant must not have write tool ${w}`)
})

Deno.test('a dispatcher can dispatch but not reach finances or system internals', () => {
  const d = names('dispatcher')
  assert(d.has('create_load'))
  assert(d.has('assign_resources'))
  assert(d.has('change_load_status'))
  assert(!d.has('bank_balance'), 'dispatcher must not see finances')
  assert(!d.has('system_status'), 'dispatcher must not see system internals')
})

Deno.test('only admin gets system_status + bank_balance alongside dispatch', () => {
  const a = names('admin')
  assert(a.has('system_status'))
  assert(a.has('bank_balance'))
  assert(a.has('create_load'))
})

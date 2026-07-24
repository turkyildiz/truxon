// deno test --allow-env supabase/functions/_shared/auth.test.ts
//
// READINESS #193: the cron/secret door. requireCron() is the only thing between
// the public internet and every privileged background job (fuel-import,
// toll-sync, notify, watchdog, sentinel, …). It compares the x-cron-key header
// to CRON_SECRET in constant time. This proves it accepts the matching key,
// rejects wrong/missing keys, and — critically — FAILS CLOSED when CRON_SECRET
// is unset (an empty secret must never authenticate an empty header).
import { assert } from 'jsr:@std/assert@1'
import { requireCron, timingSafeEqualStr } from './auth.ts'

Deno.test('timingSafeEqualStr: only identical strings match', () => {
  assert(timingSafeEqualStr('s3cr3t-abc-123', 's3cr3t-abc-123'))
  assert(!timingSafeEqualStr('s3cr3t-abc-123', 's3cr3t-abc-124'))
  assert(!timingSafeEqualStr('short', 'a-much-longer-value')) // length mismatch
  assert(!timingSafeEqualStr('', ''))                          // empty never matches
  assert(!timingSafeEqualStr('x', ''))
  assert(!timingSafeEqualStr('', 'x'))
})

Deno.test('requireCron: accepts the matching header, rejects wrong and missing', () => {
  Deno.env.set('CRON_SECRET', 'test-cron-secret-value')
  Deno.env.delete('SUPABASE_URL') // ensure the honeytoken fetch can never fire
  const req = (k?: string) =>
    new Request('https://x/y', k === undefined ? {} : { headers: { 'x-cron-key': k } })
  assert(requireCron(req('test-cron-secret-value')), 'matching key must pass')
  assert(!requireCron(req('wrong')), 'wrong key must fail')
  assert(!requireCron(req(undefined)), 'missing header must fail')
})

Deno.test('requireCron: fails closed when CRON_SECRET is unset', () => {
  Deno.env.delete('CRON_SECRET')
  Deno.env.delete('SUPABASE_URL')
  const req = new Request('https://x/y', { headers: { 'x-cron-key': 'anything' } })
  assert(!requireCron(req), 'an unset secret must never authenticate any header')
})

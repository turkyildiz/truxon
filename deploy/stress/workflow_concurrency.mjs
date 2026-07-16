// Workflow integrity under concurrency — Truxon TMS live stress test.
// Authenticated as admin. Reuses one throwaway [STRESS TEST] customer and
// inserts loads directly at the status each sub-test needs (no driver/truck
// rows). Voids every invoice at the end (SECURITY DEFINER path works); loads
// and the customer cannot be deleted (no DELETE RLS policy) so they are
// reported as leftovers.
import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const c = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)
const out = { tests: {}, createdLoads: [], createdInvoices: [], customerId: null, leftovers: {} }
const log = (...a) => console.log(...a)

const { error: le } = await c.auth.signInWithPassword({ email: 'turkyildiz@gmail.com', password: 'Towtruck505' })
if (le) { console.error('login failed:', le.message); process.exit(1) }
log('logged in as admin')

// ---- reuse or create throwaway customer ----
let custId
{
  const { data } = await c.from('customers').select('id').eq('company_name', '[STRESS TEST] delprobe').limit(1)
  if (data && data.length) custId = data[0].id
  else {
    const { data: nc } = await c.from('customers').insert({ company_name: '[STRESS TEST] wf', notes: '[STRESS TEST]' }).select('id').single()
    custId = nc.id
  }
}
out.customerId = custId
log('customer id', custId)

const insLoad = async (status, rate = 1000, miles = 100) => {
  const { data, error } = await c.from('loads')
    .insert({ customer_id: custId, status, rate, miles, notes: '[STRESS TEST]', delivery_time: '2026-07-14T12:00:00Z' })
    .select().single()
  if (error) throw new Error('insLoad ' + status + ': ' + error.message)
  out.createdLoads.push(data.id)
  return data
}
const statusLogs = async (loadId) => {
  const { data } = await c.from('activity_log').select('detail,id').eq('entity_type', 'load').eq('entity_id', loadId).eq('action', 'status_changed').order('id')
  return data || []
}
const STATES = ['pending', 'assigned', 'in_transit', 'delivered', 'completed', 'billed']
const validChain = (logs) => {
  // each detail is "X → Y"; assert Y adjacent to X and contiguous chain
  let prevTo = null, ok = true, steps = []
  for (const r of logs) {
    const m = r.detail.match(/^(\w+)\s*→\s*(\w+)/)
    if (!m) { ok = false; continue }
    const from = m[1], to = m[2]
    steps.push(from + '->' + to)
    if (Math.abs(STATES.indexOf(to) - STATES.indexOf(from)) !== 1) ok = false
    if (prevTo !== null && prevTo !== from) ok = false
    prevTo = to
  }
  return { ok, steps, final: prevTo }
}

// ============ TEST 1: concurrent change_load_status on same load ============
log('\n=== TEST 1: 20x concurrent change_load_status (same target) ===')
{
  const load = await insLoad('in_transit')
  const N = 20
  const res = await Promise.all(Array.from({ length: N }, () =>
    c.rpc('change_load_status', { p_load_id: load.id, p_status: 'delivered' })
      .then(r => ({ err: r.error?.message || null, status: r.data?.status }))))
  const ok = res.filter(r => !r.err).length
  const errs = res.filter(r => r.err)
  const { data: after } = await c.from('loads').select('status').eq('id', load.id).single()
  const logs = await statusLogs(load.id)
  const chain = validChain(logs)
  out.tests.t1_same_target = {
    loadId: load.id, apiSuccesses: ok, apiErrors: errs.length,
    errSamples: [...new Set(errs.map(e => e.err))].slice(0, 3),
    finalStatus: after.status, statusChangedLogCount: logs.length,
    chainValid: chain.ok, chainSteps: chain.steps,
    verdict: (after.status === 'delivered' && logs.length === 1 && chain.ok) ? 'PASS one-winner, no skip' : 'REVIEW',
  }
  log(JSON.stringify(out.tests.t1_same_target, null, 1))

  // Test 1b: mixed concurrent targets (fwd/back/jump) from 'delivered'
  log('\n--- TEST 1b: 20x concurrent MIXED targets (fwd/back/invalid jump) ---')
  const targets = ['completed', 'in_transit', 'billed', 'delivered']
  const res2 = await Promise.all(Array.from({ length: 20 }, (_, i) =>
    c.rpc('change_load_status', { p_load_id: load.id, p_status: targets[i % targets.length] })
      .then(r => ({ t: targets[i % 4], err: r.error?.message || null, status: r.data?.status }))))
  const { data: after2 } = await c.from('loads').select('status,rate').eq('id', load.id).single()
  const logs2 = await statusLogs(load.id)
  const chain2 = validChain(logs2)
  out.tests.t1_mixed = {
    loadId: load.id,
    successes: res2.filter(r => !r.err).length, errors: res2.filter(r => r.err).length,
    errSamples: [...new Set(res2.filter(r => r.err).map(e => e.err))].slice(0, 5),
    finalStatus: after2.status,
    fullChainValid: chain2.ok, fullChainSteps: chain2.steps,
    verdict: (chain2.ok && STATES.includes(after2.status)) ? 'PASS contiguous chain, no skipped states' : 'REVIEW state corruption',
  }
  log(JSON.stringify(out.tests.t1_mixed, null, 1))
}

// ============ TEST 2: billed-lock + concurrent void/edit ============
log('\n=== TEST 2: billed-lock + concurrent void_invoice/change_load_status ===')
{
  const load = await insLoad('completed', 2500, 200)
  const { data: inv, error: ie } = await c.rpc('create_invoice', { p_customer_id: custId, p_load_ids: [load.id] })
  if (ie) throw new Error('setup invoice: ' + ie.message)
  out.createdInvoices.push(inv.id)
  const { data: b1 } = await c.from('loads').select('status,invoice_id').eq('id', load.id).single()
  log('after invoice: load status', b1.status, 'invoice_id', b1.invoice_id, 'inv', inv.invoice_number)

  // 2a synchronous billed-lock probes
  const { error: dupd } = await c.from('loads').update({ rate: 99999 }).eq('id', load.id)
  const { error: dcls } = await c.rpc('change_load_status', { p_load_id: load.id, p_status: 'delivered' })
  const { data: b2 } = await c.from('loads').select('status,rate,invoice_id').eq('id', load.id).single()
  out.tests.t2_billed_lock = {
    loadId: load.id, invoiceId: inv.id,
    directUpdateError: dupd?.message || 'NO ERROR (LOCK FAILED)',
    changeStatusError: dcls?.message || 'NO ERROR (LOCK FAILED)',
    statusStillBilled: b2.status === 'billed', rateUnchanged: Number(b2.rate) === 2500,
    verdict: (b2.status === 'billed' && Number(b2.rate) === 2500 && dupd && dcls) ? 'PASS billed-lock holds' : 'REVIEW',
  }
  log(JSON.stringify(out.tests.t2_billed_lock, null, 1))

  // 2b concurrent race: void + edits fired together
  log('\n--- TEST 2b: concurrent void_invoice + change_load_status + direct edit ---')
  const race = await Promise.all([
    c.rpc('void_invoice', { p_invoice_id: inv.id }).then(r => ({ op: 'void', err: r.error?.message || null })),
    c.rpc('change_load_status', { p_load_id: load.id, p_status: 'delivered' }).then(r => ({ op: 'cls_delivered', err: r.error?.message || null })),
    c.rpc('change_load_status', { p_load_id: load.id, p_status: 'completed' }).then(r => ({ op: 'cls_completed', err: r.error?.message || null })),
    c.from('loads').update({ rate: 88888 }).eq('id', load.id).then(r => ({ op: 'direct_rate', err: r.error?.message || null })),
  ])
  const { data: b3 } = await c.from('loads').select('status,rate,invoice_id').eq('id', load.id).single()
  const { data: invRow } = await c.from('invoices').select('id').eq('id', inv.id)
  const orphan = (b3.invoice_id !== null) && (!invRow || invRow.length === 0) // load points to a deleted invoice
  const billedNoInvoice = b3.status === 'billed' && (!invRow || invRow.length === 0)
  out.tests.t2b_void_race = {
    ops: race,
    finalStatus: b3.status, finalInvoiceId: b3.invoice_id, invoiceRowExists: !!(invRow && invRow.length),
    orphanedInvoiceRef: orphan, billedButNoInvoice: billedNoInvoice,
    verdict: (!orphan && !billedNoInvoice) ? 'PASS no orphan, invoice atomically voided' : 'FAIL corruption',
  }
  if (invRow && invRow.length === 0) out.createdInvoices = out.createdInvoices.filter(x => x !== inv.id)
  log(JSON.stringify(out.tests.t2b_void_race, null, 1))
}

// ============ TEST 3: concurrent create_invoice on same load ============
log('\n=== TEST 3: 5x concurrent create_invoice on same completed load ===')
{
  const load = await insLoad('completed', 3300, 300)
  const N = 5
  const res = await Promise.all(Array.from({ length: N }, () =>
    c.rpc('create_invoice', { p_customer_id: custId, p_load_ids: [load.id] })
      .then(r => ({ err: r.error?.message || null, invId: r.data?.id, invNo: r.data?.invoice_number }))))
  const wins = res.filter(r => !r.err)
  const fails = res.filter(r => r.err)
  wins.forEach(w => out.createdInvoices.push(w.invId))
  const { data: lrow } = await c.from('loads').select('status,invoice_id').eq('id', load.id).single()
  // Detect double-billing: any invoice for this customer with this total not the winner
  const { data: invsForLoad } = await c.from('invoices').select('id,total,invoice_number').eq('customer_id', custId).eq('total', 3300)
  const winIds = wins.map(w => w.invId)
  const extraInvoices = (invsForLoad || []).filter(i => !winIds.includes(i.id))
  out.tests.t3_double_invoice = {
    loadId: load.id, concurrent: N, successes: wins.length, failures: fails.length,
    failSamples: [...new Set(fails.map(f => f.err))].slice(0, 3),
    loadFinalStatus: lrow.status, loadInvoiceId: lrow.invoice_id,
    winnerInvoiceIds: winIds,
    extraInvoicesWithSameTotal: extraInvoices.map(i => i.invoice_number),
    verdict: (wins.length === 1 && lrow.status === 'billed' && extraInvoices.length === 0) ? 'PASS exactly one invoice, no double-billing' : 'REVIEW possible double-billing',
  }
  log(JSON.stringify(out.tests.t3_double_invoice, null, 1))
}

// ============ CLEANUP ============
log('\n=== CLEANUP ===')
// void all invoices still present
for (const invId of [...new Set(out.createdInvoices)]) {
  const { data: exists } = await c.from('invoices').select('id').eq('id', invId)
  if (exists && exists.length) {
    const { error } = await c.rpc('void_invoice', { p_invoice_id: invId })
    log('void invoice', invId, error ? 'ERR ' + error.message : 'ok')
  }
}
// attempt to delete loads + customer (expected to be blocked by RLS)
const { data: delLoads } = await c.from('loads').delete().in('id', out.createdLoads).select('id')
const { data: delCust } = await c.from('customers').delete().eq('id', custId).select('id')
// verify leftovers
const { data: loadsLeft } = await c.from('loads').select('id,status,notes').in('id', out.createdLoads)
const { data: custLeft } = await c.from('customers').select('id').eq('id', custId)
const { data: invLeft } = await c.from('invoices').select('id').in('id', [...new Set(out.createdInvoices)])
out.leftovers = {
  loadsDeleted: delLoads ? delLoads.length : 0,
  customerDeleted: delCust ? delCust.length : 0,
  loadsStillPresent: loadsLeft ? loadsLeft.map(l => ({ id: l.id, status: l.status })) : [],
  customerStillPresent: custLeft && custLeft.length > 0 ? custId : null,
  invoicesStillPresent: invLeft ? invLeft.length : 0,
  probeCustomerFromEarlier: 205,
}
log('leftovers:', JSON.stringify(out.leftovers, null, 1))
log('\n===FULL JSON===')
log(JSON.stringify(out, null, 1))

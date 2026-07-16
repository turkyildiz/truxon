// Independent reproduction: concurrent create_invoice losers' error text.
// Finding claim: losers report 'is not completed' instead of 'already invoiced'.
import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const c = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)
const out = { trials: [], createdLoads: [], createdInvoices: [], customerId: null }
const log = (...a) => console.log(...a)

const { error: le } = await c.auth.signInWithPassword({ email: 'turkyildiz@gmail.com', password: 'Towtruck505' })
if (le) { console.error('login failed:', le.message); process.exit(1) }
log('logged in')

let custId
{
  const { data } = await c.from('customers').select('id').eq('company_name', '[STRESS TEST] wf').limit(1)
  if (data && data.length) custId = data[0].id
  else {
    const { data: nc } = await c.from('customers').insert({ company_name: '[STRESS TEST] wf', notes: '[STRESS TEST]' }).select('id').single()
    custId = nc.id
  }
}
out.customerId = custId

const insLoad = async (rate) => {
  const { data, error } = await c.from('loads')
    .insert({ customer_id: custId, status: 'completed', rate, miles: 100, notes: '[STRESS TEST]', delivery_time: '2026-07-14T12:00:00Z' })
    .select().single()
  if (error) throw new Error('insLoad: ' + error.message)
  out.createdLoads.push(data.id)
  return data
}

const N = 6
const TRIALS = 4
for (let t = 0; t < TRIALS; t++) {
  const rate = 3300 + t
  const load = await insLoad(rate)
  const res = await Promise.all(Array.from({ length: N }, () =>
    c.rpc('create_invoice', { p_customer_id: custId, p_load_ids: [load.id] })
      .then(r => ({ err: r.error?.message || null, invId: r.data?.id }))))
  const wins = res.filter(r => !r.err)
  const fails = res.filter(r => r.err)
  wins.forEach(w => out.createdInvoices.push(w.invId))
  const notCompleted = fails.filter(f => /is not completed/.test(f.err)).length
  const alreadyInv = fails.filter(f => /already invoiced/.test(f.err)).length
  const other = fails.filter(f => !/is not completed|already invoiced/.test(f.err)).map(f => f.err)
  const { data: lrow } = await c.from('loads').select('status,invoice_id').eq('id', load.id).single()
  out.trials.push({
    trial: t, loadId: load.id, successes: wins.length, failures: fails.length,
    losers_notCompleted: notCompleted, losers_alreadyInvoiced: alreadyInv, losers_other: other,
    uniqueFailMsgs: [...new Set(fails.map(f => f.err))],
    loadFinalStatus: lrow.status, loadInvoiceId: lrow.invoice_id,
    exactlyOneWinner: wins.length === 1,
  })
  log(`trial ${t}: wins=${wins.length} notCompleted=${notCompleted} alreadyInvoiced=${alreadyInv} other=${other.length}`)
}

// CLEANUP: void invoices created
log('cleanup: voiding invoices')
for (const invId of [...new Set(out.createdInvoices)].filter(Boolean)) {
  const { data: exists } = await c.from('invoices').select('id').eq('id', invId)
  if (exists && exists.length) {
    const { error } = await c.rpc('void_invoice', { p_invoice_id: invId })
    if (error) log('void err', invId, error.message)
  }
}
// try delete loads (likely blocked by RLS -> leftover [STRESS TEST] rows)
const { data: delLoads } = await c.from('loads').delete().in('id', out.createdLoads).select('id')
out.loadsDeleted = delLoads ? delLoads.length : 0
const { data: loadsLeft } = await c.from('loads').select('id').in('id', out.createdLoads)
out.loadsStillPresent = loadsLeft ? loadsLeft.length : 0

// aggregate
const agg = out.trials.reduce((a, t) => {
  a.notCompleted += t.losers_notCompleted; a.alreadyInv += t.losers_alreadyInvoiced
  a.other += t.losers_other.length; a.allOneWinner = a.allOneWinner && t.exactlyOneWinner
  return a
}, { notCompleted: 0, alreadyInv: 0, other: 0, allOneWinner: true })
out.aggregate = agg
console.log('\n=== RESULT ===')
console.log(JSON.stringify(out, null, 2))

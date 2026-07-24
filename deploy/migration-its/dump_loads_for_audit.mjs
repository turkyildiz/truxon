#!/usr/bin/env node
// Read-only: dump completed + QBO-billed loads (customer, dates, rate, ref, and
// any linked QBO invoice) to loads_audit.json, so we can cross-check billing a
// SECOND way — by customer name + delivery date (±4d) + value — independently of
// the LOAD-<ref> match. Nothing is written to prod.
//
// Usage: node dump_loads_for_audit.mjs   (prompts for admin email/password)
import { createClient } from '@supabase/supabase-js'
import { readFileSync, existsSync, writeFileSync } from 'node:fs'
import { getCreds } from './_creds.mjs'

const DIR = new URL('.', import.meta.url).pathname
const envPath = DIR + '../../frontend/.env.local'
const fileEnv = existsSync(envPath)
  ? Object.fromEntries(readFileSync(envPath, 'utf8').split('\n').filter((l) => l.includes('='))
      .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
  : {}
const SB_URL = process.env.SUPABASE_URL || fileEnv.VITE_SUPABASE_URL || 'https://okoeeyxxvzypjiumraxq.supabase.co'
const SB_ANON = process.env.SUPABASE_ANON_KEY || fileEnv.VITE_SUPABASE_ANON_KEY || 'sb_publishable_Ak8T-1XgtjC00LXbiI9xDA_o5b_n7C-'
const sb = createClient(SB_URL, SB_ANON)

const { email, password } = await getCreds()
const { error: loginErr } = await sb.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('login failed:', loginErr.message); process.exit(1) }

const sel = 'load_number,reference_number,rate,status,pickup_time,delivery_time,invoice_id,' +
            'customers(company_name),' +
            'invoices!loads_invoice_id_fkey(qbo_doc_number,total,invoice_date,status,source)'

// paginate (PostgREST caps at 1000/req)
const out = []
for (let from = 0; ; from += 1000) {
  const { data, error } = await sb.from('loads').select(sel)
    .in('status', ['completed', 'billed'])
    .order('load_number').range(from, from + 999)
  if (error) { console.error('query failed:', error.message); process.exit(1) }
  out.push(...data)
  if (data.length < 1000) break
}

const flat = out.map((l) => ({
  load_number: l.load_number,
  reference_number: l.reference_number,
  rate: Number(l.rate || 0),
  status: l.status,
  pickup: l.pickup_time,
  delivery: l.delivery_time,
  customer: l.customers?.company_name || null,
  linked_qbo_doc: l.invoices?.source === 'qbo' ? l.invoices?.qbo_doc_number : null,
  linked_total: l.invoices ? Number(l.invoices.total || 0) : null,
  linked_date: l.invoices?.invoice_date || null,
  linked_status: l.invoices?.status || null,
}))
writeFileSync(DIR + 'loads_audit.json', JSON.stringify(flat, null, 0))
const byStatus = flat.reduce((a, l) => { a[l.status] = (a[l.status] || 0) + 1; return a }, {})
const completed = flat.filter((l) => l.status === 'completed').length
const qboBilled = flat.filter((l) => l.status === 'billed' && l.linked_qbo_doc).length
console.log(`wrote ${flat.length} loads → loads_audit.json`)
console.log(`  by status: ${JSON.stringify(byStatus)}`)
console.log(`  still-unbilled (completed): ${completed}   QBO-linked (billed): ${qboBilled}`)

import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useAuth } from '../auth'
import PdfDrop from '../components/PdfDrop'
import ResourcePage from '../components/ResourcePage'
import { Badge, Button, Card, Input, money } from '../components/ui'
import { addProspect, convertProspect, createCustomer, customerEnrichmentGaps, customersMissingInfo, deleteCustomer, enrichCustomerFromRateCons, enrichCustomersBatch, enrichCustomersFromQbo, extractCustomerPdf, listCustomers, listProspects, listQuoteQueue, updateCustomer, updateProspect, updateQuote, draftQuoteResponse, type Prospect, type QuoteDraft, type QuoteRow } from '../data'
import { useNavigate } from 'react-router-dom'
import { errorMessage } from '../supabase'
import type { Customer } from '../types'

/** R9 #138: the enrichment residue — after every miner has run, what's still
 * blank, what source could still fill it, and who needs a phone call. */
function EnrichmentGapsCard() {
  const q = useQuery({ queryKey: ['enrichment-gaps'], queryFn: customerEnrichmentGaps, retry: false, staleTime: 10 * 60 * 1000 })
  const g = q.data
  if (q.isError || !g || g.fully_filled === g.customers_active) return null
  const deadEnds = g.worklist.filter((w) => w.dead_end)
  return (
    <Card title={`🧩 Contact gaps — ${g.customers_active - g.fully_filled} of ${g.customers_active} incomplete`}>
      <p className="text-sm text-body">
        Still blank: {Object.entries(g.blank_fields).filter(([, n]) => n > 0).map(([f, n]) => `${f.replace('_', ' ')} ×${n}`).join(' · ') || 'nothing'}.
        {g.dead_ends > 0 && (
          <span className="ml-1 font-semibold text-amber-600 dark:text-amber-400">
            {g.dead_ends} dead end{g.dead_ends === 1 ? '' : 's'} — no docs, mail, or QuickBooks to mine; those need a phone call.
          </span>
        )}
      </p>
      {deadEnds.length > 0 && (
        <p className="mt-1 text-xs text-muted">
          Call list: {deadEnds.slice(0, 6).map((w) => (
            <Link key={w.customer_id} className="mr-2 text-brand hover:underline" to={`/customers/${w.customer_id}`}>{w.customer}</Link>
          ))}
        </p>
      )}
      <p className="mt-1 text-[11px] text-muted">{g.note}</p>
    </Card>
  )
}

/** R9 #136: the prospect shelf — leads with an MC number and a next step.
 * Convert promotes one into a real customer row (idempotent). */
function ProspectsCard() {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const q = useQuery({ queryKey: ['prospects'], queryFn: listProspects, retry: false, staleTime: 60_000 })
  const [form, setForm] = useState({ company_name: '', contact_person: '', email: '', mc_number: '' })
  const [open, setOpen] = useState(false)
  const add = useMutation({
    mutationFn: () => addProspect(form),
    onSuccess: () => { setForm({ company_name: '', contact_person: '', email: '', mc_number: '' }); qc.invalidateQueries({ queryKey: ['prospects'] }) },
  })
  const advance = useMutation({
    mutationFn: ({ id, status }: { id: number; status: Prospect['status'] }) => updateProspect(id, { status }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['prospects'] }),
  })
  const convert = useMutation({
    mutationFn: (id: number) => convertProspect(id),
    onSuccess: (cid) => { qc.invalidateQueries({ queryKey: ['prospects'] }); qc.invalidateQueries({ queryKey: ['customers-all'] }); navigate(`/customers/${cid}`) },
  })
  const rows = q.data ?? []
  if (q.isError) return null
  return (
    <Card title={`🌱 Prospects${rows.length ? ` (${rows.length})` : ''}`}>
      {rows.length === 0 && <p className="text-sm text-muted">No open leads. Add the brokers you're courting — vet status and next step live here until they convert.</p>}
      <ul className="space-y-1.5">
        {rows.map((p) => (
          <li key={p.id} className="flex flex-wrap items-center justify-between gap-2 rounded border border-edge p-2 text-sm">
            <span>
              <span className="font-medium">{p.company_name}</span>
              <span className="ml-2 text-xs text-muted">
                {[p.contact_person, p.email, p.mc_number && `MC ${p.mc_number}`].filter(Boolean).join(' · ')}
                {p.fmcsa_checked_at == null && ' · unvetted'}
              </span>
            </span>
            <span className="flex items-center gap-2">
              <select
                className="rounded border border-edge bg-transparent px-1 py-0.5 text-xs"
                value={p.status}
                onChange={(e) => advance.mutate({ id: p.id, status: e.target.value as Prospect['status'] })}
              >
                {['new', 'contacted', 'quoting', 'dead'].map((s) => <option key={s} value={s}>{s}</option>)}
              </select>
              <Button type="button" className="!py-1 text-xs" disabled={convert.isPending}
                onClick={() => convert.mutate(p.id)}>
                → Customer
              </Button>
            </span>
          </li>
        ))}
      </ul>
      {open ? (
        <form className="mt-3 flex flex-wrap gap-2" onSubmit={(e) => { e.preventDefault(); if (form.company_name.trim()) add.mutate() }}>
          <Input className="w-44 !py-1 text-xs" placeholder="Company *" value={form.company_name} onChange={(e) => setForm({ ...form, company_name: e.target.value })} />
          <Input className="w-32 !py-1 text-xs" placeholder="Contact" value={form.contact_person} onChange={(e) => setForm({ ...form, contact_person: e.target.value })} />
          <Input className="w-40 !py-1 text-xs" placeholder="Email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
          <Input className="w-28 !py-1 text-xs" placeholder="MC #" value={form.mc_number} onChange={(e) => setForm({ ...form, mc_number: e.target.value })} />
          <Button type="submit" className="!py-1 text-xs" disabled={add.isPending || !form.company_name.trim()}>Add</Button>
        </form>
      ) : (
        <button type="button" className="mt-2 text-xs font-medium text-brand hover:underline" onClick={() => setOpen(true)}>+ Add prospect</button>
      )}
      {(add.isError || convert.isError) && <p className="mt-1 text-xs text-red-600">{errorMessage(add.error ?? convert.error)}</p>}
    </Card>
  )
}

/** R9 #129: the quote queue — record what we quoted, then the outcome, so
 * the pricing report can say why we win and lose. */
function QuoteQueueCard() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['quote-queue'], queryFn: listQuoteQueue, retry: false, refetchInterval: 5 * 60_000 })
  const [rates, setRates] = useState<Record<number, string>>({})
  const [reasons, setReasons] = useState<Record<number, string>>({})
  const [drafts, setDrafts] = useState<Record<number, QuoteDraft>>({})
  const mut = useMutation({
    mutationFn: ({ id, patch }: { id: number; patch: Parameters<typeof updateQuote>[1] }) => updateQuote(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['quote-queue'] }),
  })
  // R9 #128: propose-only reply draft from our lane book; prefills the rate.
  const draft = useMutation({
    mutationFn: (id: number) => draftQuoteResponse(id),
    onSuccess: (d) => {
      if (!d) return
      setDrafts((prev) => ({ ...prev, [d.quote_id]: d }))
      if (d.suggested_rate != null) setRates((prev) => ({ ...prev, [d.quote_id]: String(d.suggested_rate) }))
    },
  })
  const rows = q.data ?? []
  if (q.isError || rows.length === 0) return null
  const laneOf = (r: QuoteRow) =>
    `${r.origin_city || r.origin_zip}, ${r.origin_state} → ${r.dest_city || r.dest_zip}, ${r.dest_state}`
  return (
    <Card title={`📨 Quote queue (${rows.length})`}>
      {mut.isError && <p className="mb-2 text-xs text-red-600">{errorMessage(mut.error)}</p>}
      <ul className="space-y-2">
        {rows.map((r) => (
          <li key={r.id} className="rounded border border-edge p-2 text-sm">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span>
                <span className="font-medium">{r.company || r.contact_name}</span>{' '}
                <span className="text-muted">· {laneOf(r)}{r.equipment ? ` · ${r.equipment}` : ''}{r.pickup_date ? ` · pu ${r.pickup_date}` : ''}</span>
                {r.status === 'quoted' && r.quoted_rate != null && (
                  <span className="ml-1 font-semibold text-brand">quoted {money(r.quoted_rate)}</span>
                )}
              </span>
              <span className="flex items-center gap-2">
                {r.status === 'new' && (
                  <>
                    <Button type="button" variant="secondary" className="!py-1 text-xs" disabled={draft.isPending}
                      onClick={() => draft.mutate(r.id)}>
                      💡 Draft
                    </Button>
                    <Input className="w-24 !py-1 text-xs" placeholder="$ rate" inputMode="decimal"
                      value={rates[r.id] ?? ''} onChange={(e) => setRates({ ...rates, [r.id]: e.target.value })} />
                    <Button type="button" className="!py-1 text-xs" disabled={mut.isPending || !Number(rates[r.id])}
                      onClick={() => mut.mutate({ id: r.id, patch: { status: 'quoted', quoted_rate: Number(rates[r.id]), quoted_at: new Date().toISOString() } })}>
                      Quoted
                    </Button>
                  </>
                )}
                {r.status === 'quoted' && (
                  <>
                    <Button type="button" className="!py-1 text-xs" disabled={mut.isPending}
                      onClick={() => mut.mutate({ id: r.id, patch: { status: 'won' } })}>
                      ✓ Won
                    </Button>
                    <Input className="w-32 !py-1 text-xs" placeholder="lost because…"
                      value={reasons[r.id] ?? ''} onChange={(e) => setReasons({ ...reasons, [r.id]: e.target.value })} />
                    <Button type="button" variant="secondary" className="!py-1 text-xs" disabled={mut.isPending}
                      onClick={() => mut.mutate({ id: r.id, patch: { status: 'lost', lost_reason: (reasons[r.id] ?? '').trim() } })}>
                      ✗ Lost
                    </Button>
                  </>
                )}
              </span>
            </div>
            {r.notes && <p className="mt-1 text-xs text-muted">{r.notes}</p>}
            {drafts[r.id] && (
              <div className="mt-2 rounded bg-surface-2 p-2 text-xs">
                {drafts[r.id].no_history ? (
                  <p className="text-muted">{drafts[r.id].note}</p>
                ) : (
                  <>
                    <p className="mb-1 text-muted">
                      Suggested <span className="font-semibold text-body">{money(drafts[r.id].suggested_rate ?? 0)}</span> — {drafts[r.id].note}
                      <button type="button" className="ml-2 font-medium text-brand hover:underline"
                        onClick={() => void navigator.clipboard.writeText(drafts[r.id].draft_text ?? '')}>
                        Copy reply
                      </button>
                    </p>
                    <pre className="whitespace-pre-wrap font-sans text-body">{drafts[r.id].draft_text}</pre>
                  </>
                )}
              </div>
            )}
          </li>
        ))}
      </ul>
      <p className="mt-1 text-[11px] text-muted">
        Record the rate when you quote it; mark the outcome when you hear back. The pricing report on Reports learns from every answer.
      </p>
    </Card>
  )
}

export default function Customers() {
  const { user } = useAuth()
  const qc = useQueryClient()
  const [prefill, setPrefill] = useState<Record<string, unknown> | null>(null)
  const [note, setNote] = useState('')
  const [enriching, setEnriching] = useState(false)
  const [enrichNote, setEnrichNote] = useState('')
  const [scanning, setScanning] = useState(false)
  const [scanNote, setScanNote] = useState('')

  async function runEnrich() {
    setEnriching(true)
    let filled = 0, touched = 0
    try {
      // 1) QuickBooks first — structured, fast, best for billing/email/contact
      setEnrichNote('Pulling contact details from QuickBooks…')
      const qbo = await enrichCustomersFromQbo()
      filled += qbo.filledTotal
      touched += qbo.touched
      setEnrichNote(`QuickBooks filled ${qbo.filledTotal} fields on ${qbo.touched} customers. Now checking documents…`)
      // 2) Documents — fills any remaining blanks where a text rate-con exists
      let afterId = 0, scanned = 0
      for (let i = 0; i < 200; i++) {
        const r = await enrichCustomersBatch(afterId, true)
        if (r.processed === 0 || r.lastId <= afterId) break
        scanned += r.processed
        filled += r.filledTotal
        touched += r.customers.filter((c) => c.filled > 0).length
        afterId = r.lastId
        setEnrichNote(`QuickBooks + documents: filled ${filled} blank fields on ${touched} customers so far…`)
      }
      setEnrichNote(`✓ Done — filled ${filled} blank field(s) across ${touched} customer(s) from QuickBooks + documents.`)
      qc.invalidateQueries({ queryKey: ['customers-all'] })
    } catch (e) {
      setEnrichNote(errorMessage(e))
    } finally {
      setEnriching(false)
    }
  }

  // 3rd source: vision-read each customer's loads' rate confirmations (scanned
  // PDFs) in the browser. Slow + rate-limited (30 AI reads/hour), so it stops
  // cleanly at the cap and can be resumed later.
  async function runRateConScan() {
    setScanning(true)
    setScanNote('Finding customers still missing contact info…')
    try {
      const missing = await customersMissingInfo()
      let done = 0, filled = 0, touched = 0, rateLimited = false
      for (const c of missing) {
        try {
          const n = await enrichCustomerFromRateCons(c.id, c.company_name)
          if (n > 0) { filled += n; touched++ }
        } catch (err) {
          if (err instanceof Error && err.message === 'RATE_LIMIT') { rateLimited = true; break }
          // skip this customer on any other error
        }
        done++
        setScanNote(`Read ${done}/${missing.length} customers’ rate confirmations… filled ${filled} fields on ${touched}`)
      }
      qc.invalidateQueries({ queryKey: ['customers-all'] })
      setScanNote(rateLimited
        ? `Paused at the hourly AI limit after ${done} customer(s) — filled ${filled} fields on ${touched}. Run again in an hour to continue.`
        : `✓ Rate-con scan done — filled ${filled} field(s) on ${touched} customer(s) (${done} scanned).`)
    } catch (e) {
      setScanNote(errorMessage(e))
    } finally {
      setScanning(false)
    }
  }

  const extract = useMutation({
    mutationFn: async (file: File) => {
      setNote('')
      const first = await extractCustomerPdf(file)
      if (first.needs_images) {
        setNote('Scanned PDF — reading pages with vision AI…')
        const { renderPdfPages } = await import('../pdfPages')
        const pages = await renderPdfPages(file)
        if (pages.length > 0) return extractCustomerPdf(file, pages)
      }
      return first
    },
    onSuccess: (result) => {
      if (result.error && !result.fields) {
        setNote(result.error)
        return
      }
      const f = result.fields ?? {}
      setPrefill({
        company_name: f.company_name ?? '',
        contact_person: f.contact_person ?? '',
        phone: f.phone ?? '',
        email: f.email ?? '',
        payment_terms: f.payment_terms ?? 'Net 30',
        billing_address: f.billing_address ?? '',
        notes: [f.mc_number ? `MC# ${f.mc_number}` : '', f.notes ?? ''].filter(Boolean).join(' — '),
        is_active: true,
      })
      setNote('✓ Details extracted — review and save')
    },
    onError: (err) => setNote(errorMessage(err)),
  })

  return (
    <div className="space-y-4">
      <div className="flex justify-end">
        <button
          type="button"
          className="rounded-lg border border-line px-3 py-1.5 text-sm font-medium text-muted hover:text-body"
          title='Merges every PDF in the Team Drive folder "Broker Packet" (W9, COI, authority…) into one carrier packet with a cover page'
          onClick={() => void import('../invoicePdf').then(async (m) => {
            const r = await m.downloadBrokerPacket()
            if (r === 'empty') setNote('Broker Packet folder is empty — drop your W9, COI, and authority PDFs into Team Drive → "Broker Packet" first.')
          })}
        >📎 Carrier packet</button>
      </div>
      {(user?.role === 'admin' || user?.role === 'dispatcher') && <QuoteQueueCard />}
      {(user?.role === 'admin' || user?.role === 'dispatcher') && <ProspectsCard />}
      {user?.role === 'admin' && <EnrichmentGapsCard />}
      <PdfDrop
        title="Quick Add from Paperwork"
        hint="Drop a rate confirmation or broker setup packet here to add the customer"
        busy={extract.isPending}
        note={note}
        onFile={(f) => extract.mutate(f)}
      />
      {user?.role === 'admin' && (
        <div className="flex flex-wrap items-center gap-3 rounded-lg border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-800">
          <button
            type="button"
            onClick={runEnrich}
            disabled={enriching}
            className="rounded-md bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-50"
          >
            {enriching ? 'Filling…' : 'Fill blanks (QuickBooks + documents)'}
          </button>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            {enrichNote || 'Forest fills only the empty fields from QuickBooks and each customer’s paperwork — never overwrites what’s there.'}
          </span>
        </div>
      )}
      {user?.role === 'admin' && (
        <div className="flex flex-wrap items-center gap-3 rounded-lg border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-800">
          <button
            type="button"
            onClick={runRateConScan}
            disabled={scanning}
            className="rounded-md bg-purple-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-purple-700 disabled:opacity-50"
          >
            {scanning ? 'Scanning…' : 'Scan rate confirmations (vision AI)'}
          </button>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            {scanNote || 'Last resort for still-blank fields: reads each customer’s scanned rate cons with vision AI. Slow, and limited to 30 reads/hour — run again to continue.'}
          </span>
        </div>
      )}
      <ResourcePage<Customer>
        title="Customers"
        queryKey="customers-all"
        emptyCoach={<>No customers yet. The fastest start: drop a rate confirmation into &ldquo;Quick Add from Paperwork&rdquo; above and the broker is created for you — or add one manually.</>}
        list={(q) => listCustomers(q, { includeInactive: true })}
        create={createCustomer}
        update={updateCustomer}
        prefill={prefill}
        onPrefillConsumed={() => setPrefill(null)}
        docs={{ entityType: 'customer', docTypes: ['Contract', 'Rate Agreement', 'Insurance', 'Other'], label: (c) => c.company_name }}
        defaultSort={{ key: 'company', dir: 'asc' }}
        columns={[
          { header: 'Company', sortKey: 'company', sortValue: (c) => c.company_name, render: (c) => <Link className="font-medium text-brand hover:underline" to={`/customers/${c.id}`} onClick={(e) => e.stopPropagation()}>{c.company_name}</Link> },
          { header: 'Contact', sortKey: 'contact', sortValue: (c) => c.contact_person, render: (c) => c.contact_person || '—' },
          { header: 'Phone', sortKey: 'phone', sortValue: (c) => c.phone, render: (c) => c.phone || '—' },
          { header: 'Email', sortKey: 'email', sortValue: (c) => c.email, render: (c) => c.email || '—' },
          { header: 'Terms', sortKey: 'terms', sortValue: (c) => c.payment_terms, render: (c) => c.payment_terms },
          {
            header: 'Status',
            sortKey: 'status',
            sortValue: (c) => (c.do_not_use ? 'do not use' : c.is_active ? 'active' : 'inactive'),
            render: (c) =>
              c.do_not_use ? (
                <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700 dark:bg-red-900/40 dark:text-red-300">Do Not Use</span>
              ) : (
                <Badge status={c.is_active ? 'active' : 'inactive'} />
              ),
          },
        ]}
        fields={[
          { name: 'company_name', label: 'Company Name', required: true },
          { name: 'contact_person', label: 'Contact Person' },
          { name: 'phone', label: 'Phone' },
          { name: 'email', label: 'Email' },
          { name: 'fax', label: 'Fax' },
          { name: 'toll_free', label: 'Toll Free' },
          { name: 'secondary_contact', label: 'Secondary Contact' },
          { name: 'secondary_phone', label: 'Secondary Phone' },
          { name: 'secondary_email', label: 'Secondary Email' },
          { name: 'payment_terms', label: 'Payment Terms' },
          { name: 'is_active', label: 'Active', type: 'checkbox' },
          { name: 'do_not_use', label: 'Do Not Use (blacklist)', type: 'checkbox' },
          { name: 'billing_address', label: 'Billing Address', type: 'textarea', full: true },
          { name: 'notes', label: 'Notes', type: 'textarea', full: true },
        ]}
        defaults={{ company_name: '', contact_person: '', phone: '', email: '', fax: '', toll_free: '', secondary_contact: '', secondary_phone: '', secondary_email: '', payment_terms: 'Net 30', billing_address: '', notes: '', is_active: true, do_not_use: false }}
        toForm={(c) => ({
          company_name: c.company_name,
          contact_person: c.contact_person,
          phone: c.phone,
          email: c.email,
          fax: c.fax,
          toll_free: c.toll_free,
          secondary_contact: c.secondary_contact,
          secondary_phone: c.secondary_phone,
          secondary_email: c.secondary_email,
          payment_terms: c.payment_terms,
          billing_address: c.billing_address,
          notes: c.notes,
          is_active: c.is_active,
          do_not_use: c.do_not_use,
        })}
        remove={user?.role === 'admin' ? {
          fn: deleteCustomer,
          confirm: (c) => `Delete "${c.company_name}" permanently?\n\nOnly allowed if we've never hauled their cargo (no loads or invoices). Otherwise use the Inactive or Do Not Use toggles instead.`,
        } : undefined}
      />
    </div>
  )
}

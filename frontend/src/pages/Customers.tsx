import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useAuth } from '../auth'
import PdfDrop from '../components/PdfDrop'
import ResourcePage from '../components/ResourcePage'
import { Badge } from '../components/ui'
import { createCustomer, enrichCustomersBatch, extractCustomerPdf, listCustomers, updateCustomer } from '../data'
import { errorMessage } from '../supabase'
import type { Customer } from '../types'

export default function Customers() {
  const { user } = useAuth()
  const qc = useQueryClient()
  const [prefill, setPrefill] = useState<Record<string, unknown> | null>(null)
  const [note, setNote] = useState('')
  const [enriching, setEnriching] = useState(false)
  const [enrichNote, setEnrichNote] = useState('')

  async function runEnrich() {
    setEnriching(true)
    setEnrichNote('Reading customer documents…')
    let afterId = 0, scanned = 0, filled = 0, touched = 0
    try {
      // page through every customer with blanks; the RPC only ever fills empties
      for (let i = 0; i < 200; i++) {
        const r = await enrichCustomersBatch(afterId, true)
        if (r.processed === 0 || r.lastId <= afterId) break
        scanned += r.processed
        filled += r.filledTotal
        touched += r.customers.filter((c) => c.filled > 0).length
        afterId = r.lastId
        setEnrichNote(`Scanned ${scanned} customers… filled ${filled} blank fields on ${touched} so far`)
      }
      setEnrichNote(`✓ Done — filled ${filled} blank field(s) across ${touched} customer(s) from their documents (${scanned} scanned).`)
      qc.invalidateQueries({ queryKey: ['customers-all'] })
    } catch (e) {
      setEnrichNote(errorMessage(e))
    } finally {
      setEnriching(false)
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
            {enriching ? 'Filling…' : 'Fill blanks from documents'}
          </button>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            {enrichNote || 'Trux reads each customer’s paperwork and fills only the empty fields — never overwrites what’s there.'}
          </span>
        </div>
      )}
      <ResourcePage<Customer>
        title="Customers"
        queryKey="customers-all"
        list={(q) => listCustomers(q, { includeInactive: true })}
        create={createCustomer}
        update={updateCustomer}
        prefill={prefill}
        onPrefillConsumed={() => setPrefill(null)}
        docs={{ entityType: 'customer', docTypes: ['Contract', 'Rate Agreement', 'Insurance', 'Other'], label: (c) => c.company_name }}
        columns={[
          { header: 'Company', render: (c) => <span className="font-medium">{c.company_name}</span> },
          { header: 'Contact', render: (c) => c.contact_person || '—' },
          { header: 'Phone', render: (c) => c.phone || '—' },
          { header: 'Email', render: (c) => c.email || '—' },
          { header: 'Terms', render: (c) => c.payment_terms },
          { header: 'Status', render: (c) => <Badge status={c.is_active ? 'active' : 'inactive'} /> },
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
          { name: 'billing_address', label: 'Billing Address', type: 'textarea', full: true },
          { name: 'notes', label: 'Notes', type: 'textarea', full: true },
        ]}
        defaults={{ company_name: '', contact_person: '', phone: '', email: '', fax: '', toll_free: '', secondary_contact: '', secondary_phone: '', secondary_email: '', payment_terms: 'Net 30', billing_address: '', notes: '', is_active: true }}
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
        })}
      />
    </div>
  )
}

import ResourcePage from '../components/ResourcePage'
import { Badge } from '../components/ui'
import { createCustomer, listCustomers, updateCustomer } from '../data'
import type { Customer } from '../types'

export default function Customers() {
  return (
    <ResourcePage<Customer>
      title="Customers"
      queryKey="customers"
      list={listCustomers}
      create={createCustomer}
      update={updateCustomer}
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
        { name: 'payment_terms', label: 'Payment Terms' },
        { name: 'is_active', label: 'Active', type: 'checkbox' },
        { name: 'billing_address', label: 'Billing Address', type: 'textarea', full: true },
        { name: 'notes', label: 'Notes', type: 'textarea', full: true },
      ]}
      defaults={{ company_name: '', contact_person: '', phone: '', email: '', payment_terms: 'Net 30', billing_address: '', notes: '', is_active: true }}
      toForm={(c) => ({
        company_name: c.company_name,
        contact_person: c.contact_person,
        phone: c.phone,
        email: c.email,
        payment_terms: c.payment_terms,
        billing_address: c.billing_address,
        notes: c.notes,
        is_active: c.is_active,
      })}
    />
  )
}

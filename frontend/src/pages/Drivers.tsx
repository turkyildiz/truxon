import ResourcePage from '../components/ResourcePage'
import { Badge, formatDate } from '../components/ui'
import { createDriver, listDrivers, updateDriver } from '../data'
import type { Driver } from '../types'

export default function Drivers() {
  return (
    <ResourcePage<Driver>
      title="Drivers"
      queryKey="drivers"
      list={listDrivers}
      create={createDriver}
      update={updateDriver}
      columns={[
        { header: 'Name', render: (d) => <span className="font-medium">{d.full_name}</span> },
        { header: 'Phone', render: (d) => d.phone || '—' },
        { header: 'License #', render: (d) => d.license_number || '—' },
        {
          header: 'License Exp.',
          render: (d) => {
            const expired = d.license_expiration && new Date(d.license_expiration) < new Date()
            const soon = d.license_expiration && !expired && new Date(d.license_expiration) < new Date(Date.now() + 30 * 864e5)
            return <span className={expired ? 'font-semibold text-red-600' : soon ? 'font-semibold text-amber-600' : ''}>{formatDate(d.license_expiration)}</span>
          },
        },
        { header: 'Hired', render: (d) => formatDate(d.hire_date) },
        { header: 'Pay/Mile', render: (d) => `$${Number(d.pay_per_mile).toFixed(2)}` },
        { header: 'Status', render: (d) => <Badge status={d.status} /> },
      ]}
      fields={[
        { name: 'full_name', label: 'Full Name', required: true },
        { name: 'phone', label: 'Phone' },
        { name: 'email', label: 'Email', type: 'email' },
        { name: 'address', label: 'Address' },
        { name: 'city', label: 'City' },
        { name: 'state', label: 'State' },
        { name: 'license_number', label: 'License Number' },
        { name: 'license_expiration', label: 'License Expiration', type: 'date' },
        { name: 'date_of_birth', label: 'Date of Birth', type: 'date' },
        { name: 'hire_date', label: 'Hire Date', type: 'date' },
        { name: 'pay_per_mile', label: 'Pay Per Mile ($)', type: 'number', step: '0.001' },
        { name: 'pay_per_empty_mile', label: 'Pay Per Empty Mile ($)', type: 'number', step: '0.001' },
        {
          name: 'status',
          label: 'Status',
          type: 'select',
          required: true,
          options: [
            { value: 'active', label: 'Active' },
            { value: 'inactive', label: 'Inactive' },
            { value: 'terminated', label: 'Terminated' },
          ],
        },
        { name: 'notes', label: 'Notes (medical, drug tests…)', type: 'textarea', full: true },
      ]}
      docs={{ entityType: 'driver', docTypes: ['License', 'Medical Card', 'Employment', 'Other'], label: (d) => d.full_name }}
      defaults={{ full_name: '', phone: '', email: '', address: '', city: '', state: '', license_number: '', license_expiration: '', date_of_birth: '', hire_date: '', pay_per_mile: '0', pay_per_empty_mile: '0', status: 'active', notes: '' }}
      toForm={(d) => ({
        full_name: d.full_name,
        phone: d.phone,
        email: d.email,
        address: d.address,
        city: d.city,
        state: d.state,
        license_number: d.license_number,
        license_expiration: d.license_expiration ?? '',
        date_of_birth: d.date_of_birth ?? '',
        hire_date: d.hire_date ?? '',
        pay_per_mile: d.pay_per_mile,
        pay_per_empty_mile: d.pay_per_empty_mile,
        status: d.status,
        notes: d.notes,
      })}
    />
  )
}

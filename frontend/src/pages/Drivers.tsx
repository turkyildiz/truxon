import { useQuery } from '@tanstack/react-query'
import ResourcePage from '../components/ResourcePage'
import { Badge, Card, formatDate } from '../components/ui'
import { createDriver, driverQualFiles, listDrivers, listLinkableDriverProfiles, updateDriver } from '../data'
import type { Driver } from '../types'

/** The screen a DOT auditor walks in with: per-driver CDL / med-card record
 * completeness AND whether the paper is actually on file. */
function QualFilesCard() {
  const q = useQuery({ queryKey: ['driver-qual-files'], queryFn: driverQualFiles, retry: false })
  const d = q.data
  if (q.isError || !d || d.total === 0) return null
  const mark = (ok: boolean) => (ok ? '✓' : '✗')
  const cls = (ok: boolean) => (ok ? 'text-green-600 dark:text-green-300' : 'font-semibold text-red-600 dark:text-red-300')
  const incomplete = d.drivers.filter((r) => !r.complete)
  if (incomplete.length === 0) {
    return (
      <Card title="🗂️ Driver qualification files">
        <p className="text-sm text-green-700 dark:text-green-300">All {d.total} active drivers audit-ready ✓</p>
      </Card>
    )
  }
  return (
    <Card title={`🗂️ Driver qualification files — ${d.complete_count}/${d.total} audit-ready`}>
      <p className="mb-2 text-xs text-muted">
        An auditor asks for exactly this. ✗ = missing. Fix records in Edit; photograph the CDL and
        medical card into each driver's 📄 Docs (types "License" and "Medical Card").
      </p>
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="text-left text-xs uppercase tracking-wide text-muted">
            <th className="px-3 py-2">Driver</th><th className="px-3 py-2">CDL #</th>
            <th className="px-3 py-2">CDL exp</th><th className="px-3 py-2">Med card</th>
            <th className="px-3 py-2">CDL doc</th><th className="px-3 py-2">Med doc</th>
          </tr></thead>
          <tbody>
            {incomplete.map((r) => (
              <tr key={r.driver_id} className="border-t border-line">
                <td className="px-3 py-2 font-medium">{r.driver}</td>
                <td className={`px-3 py-2 ${cls(r.cdl_number_on_record)}`}>{mark(r.cdl_number_on_record)}</td>
                <td className={`px-3 py-2 ${cls(!!r.cdl_ok)}`}>{r.cdl_expiry ? formatDate(r.cdl_expiry) : '✗'}</td>
                <td className={`px-3 py-2 ${cls(!!r.medcard_ok)}`}>{r.medcard_expiry ? formatDate(r.medcard_expiry) : '✗'}</td>
                <td className={`px-3 py-2 ${cls(r.license_doc_on_file)}`}>{mark(r.license_doc_on_file)}</td>
                <td className={`px-3 py-2 ${cls(r.medcard_doc_on_file)}`}>{mark(r.medcard_doc_on_file)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Card>
  )
}

export default function Drivers() {
  return (
    <>
    <QualFilesCard />
    <ResourcePage<Driver>
      title="Drivers"
      queryKey="drivers"
      list={listDrivers}
      create={createDriver}
      update={updateDriver}
      defaultSort={{ key: 'name', dir: 'asc' }}
      columns={[
        { header: 'Name', sortKey: 'name', sortValue: (d) => d.full_name, render: (d) => <span className="font-medium">{d.full_name}</span> },
        { header: 'Phone', sortKey: 'phone', sortValue: (d) => d.phone, render: (d) => d.phone || '—' },
        { header: 'License #', sortKey: 'license', sortValue: (d) => d.license_number, render: (d) => d.license_number || '—' },
        {
          header: 'License Exp.',
          sortKey: 'license_exp',
          sortValue: (d) => (d.license_expiration ? new Date(d.license_expiration).getTime() : null),
          render: (d) => {
            const expired = d.license_expiration && new Date(d.license_expiration) < new Date()
            const soon = d.license_expiration && !expired && new Date(d.license_expiration) < new Date(Date.now() + 30 * 864e5)
            return <span className={expired ? 'font-semibold text-red-600' : soon ? 'font-semibold text-amber-600' : ''}>{formatDate(d.license_expiration)}</span>
          },
        },
        { header: 'Hired', sortKey: 'hired', sortValue: (d) => (d.hire_date ? new Date(d.hire_date).getTime() : null), render: (d) => formatDate(d.hire_date) },
        { header: 'Pay/Mile', sortKey: 'pay_per_mile', sortValue: (d) => Number(d.pay_per_mile), render: (d) => `$${Number(d.pay_per_mile).toFixed(2)}` },
        {
          header: 'Login',
          sortKey: 'login',
          sortValue: (d) => !!d.user_id,
          render: (d) => (d.user_id ? <span className="text-sm text-muted">Linked</span> : <span className="text-muted">—</span>),
        },
        { header: 'Status', sortKey: 'status', sortValue: (d) => d.status, render: (d) => <Badge status={d.status} /> },
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
        { name: 'medical_card_number', label: 'Medical Card #' },
        { name: 'medical_card_expiry', label: 'Medical Card Expiry', type: 'date' },
        { name: 'date_of_birth', label: 'Date of Birth', type: 'date' },
        { name: 'hire_date', label: 'Hire Date', type: 'date' },
        { name: 'pay_per_mile', label: 'Pay Per Mile ($)', type: 'number', step: '0.001' },
        { name: 'empty_miles_paid', label: 'Empty Miles Paid', type: 'checkbox' },
        { name: 'pay_per_empty_mile', label: 'Empty-Mile Rate ($)', type: 'number', step: '0.001', showIf: (f) => !!f.empty_miles_paid },
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
        { name: 'user_id', label: 'Linked login (driver role)', type: 'select' },
        { name: 'notes', label: 'Notes (medical, drug tests…)', type: 'textarea', full: true },
      ]}
      docs={{ entityType: 'driver', docTypes: ['License', 'Medical Card', 'Employment', 'Other'], label: (d) => d.full_name }}
      defaults={{ full_name: '', phone: '', email: '', address: '', city: '', state: '', license_number: '', license_expiration: '', medical_card_number: '', medical_card_expiry: '', date_of_birth: '', hire_date: '', pay_per_mile: '0', empty_miles_paid: false, pay_per_empty_mile: '0', status: 'active', user_id: '', notes: '' }}
      toForm={(d) => ({
        full_name: d.full_name,
        phone: d.phone,
        email: d.email,
        address: d.address,
        city: d.city,
        state: d.state,
        license_number: d.license_number,
        license_expiration: d.license_expiration ?? '',
        medical_card_number: d.medical_card_number ?? '',
        medical_card_expiry: d.medical_card_expiry ?? '',
        date_of_birth: d.date_of_birth ?? '',
        hire_date: d.hire_date ?? '',
        pay_per_mile: d.pay_per_mile,
        empty_miles_paid: d.empty_miles_paid,
        pay_per_empty_mile: d.pay_per_empty_mile,
        status: d.status,
        user_id: d.user_id ?? '',
        notes: d.notes,
      })}
      fieldOptionsLoader={async (item) => {
        const profiles = await listLinkableDriverProfiles(item?.user_id ?? null)
        return {
          user_id: profiles.map((p) => ({
            value: p.id,
            label: `${p.username}${p.full_name ? ` (${p.full_name})` : ''}`,
          })),
        }
      }}
    />
    </>
  )
}

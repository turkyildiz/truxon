import { useQuery } from '@tanstack/react-query'
import ResourcePage from '../components/ResourcePage'
import { Badge, formatDate } from '../components/ui'
import { createDriver, listDrivers, listLinkableDriverProfiles, listUsers, updateDriver } from '../data'
import type { Driver } from '../types'
import { useAuth } from '../auth'

export default function Drivers() {
  const { user } = useAuth()
  const isAdmin = user?.role === 'admin'

  // Admins can list all users via edge function for richer labels; others use profiles table.
  const { data: allUsers = [] } = useQuery({
    queryKey: ['users-for-driver-link'],
    queryFn: async () => {
      if (isAdmin) {
        try {
          return await listUsers()
        } catch {
          return []
        }
      }
      return []
    },
    enabled: isAdmin,
  })

  return (
    <ResourcePage<Driver>
      title="Drivers"
      queryKey="drivers"
      list={listDrivers}
      create={createDriver}
      update={updateDriver}
      columns={[
        { header: 'Name', render: (d) => <span className="font-medium">{d.full_name}</span> },
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
        {
          header: 'Login',
          render: (d) => {
            if (!d.user_id) return <span className="text-slate-400">—</span>
            const u = allUsers.find((x) => x.id === d.user_id)
            return <span className="text-sm text-slate-600">{u?.username || u?.email || 'Linked'}</span>
          },
        },
        { header: 'Status', render: (d) => <Badge status={d.status} /> },
      ]}
      fields={[
        { name: 'full_name', label: 'Full Name', required: true },
        { name: 'license_number', label: 'License Number' },
        { name: 'license_expiration', label: 'License Expiration', type: 'date' },
        { name: 'date_of_birth', label: 'Date of Birth', type: 'date' },
        { name: 'hire_date', label: 'Hire Date', type: 'date' },
        { name: 'pay_per_mile', label: 'Pay Per Mile ($)', type: 'number', step: '0.001' },
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
        {
          name: 'user_id',
          label: 'Linked login (driver role)',
          type: 'select',
          options: [], // filled dynamically via DynamicDriverForm — see below wrapper
        },
      ]}
      defaults={{ full_name: '', license_number: '', license_expiration: '', date_of_birth: '', hire_date: '', pay_per_mile: '0', status: 'active', user_id: '' }}
      toForm={(d) => ({
        full_name: d.full_name,
        license_number: d.license_number,
        license_expiration: d.license_expiration ?? '',
        date_of_birth: d.date_of_birth ?? '',
        hire_date: d.hire_date ?? '',
        pay_per_mile: d.pay_per_mile,
        status: d.status,
        user_id: d.user_id ?? '',
      })}
      fieldOptionsLoader={async (item) => {
        const current = item?.user_id ?? null
        const profiles = await listLinkableDriverProfiles(current)
        return {
          user_id: profiles.map((p) => ({
            value: p.id,
            label: `${p.username}${p.full_name ? ` (${p.full_name})` : ''}`,
          })),
        }
      }}
    />
  )
}

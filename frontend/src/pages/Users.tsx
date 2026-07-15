import ResourcePage from '../components/ResourcePage'
import { Badge } from '../components/ui'
import type { User } from '../types'

const ROLE_OPTIONS = [
  { value: 'admin', label: 'Admin' },
  { value: 'dispatcher', label: 'Dispatcher' },
  { value: 'driver', label: 'Driver' },
  { value: 'accountant', label: 'Accountant' },
  { value: 'maintenance', label: 'Maintenance' },
]

export default function Users() {
  return (
    <ResourcePage<User>
      title="Users"
      endpoint="/users"
      searchable={false}
      columns={[
        { header: 'Username', render: (u) => <span className="font-medium">{u.username}</span> },
        { header: 'Full Name', render: (u) => u.full_name || '—' },
        { header: 'Role', render: (u) => <span className="capitalize">{u.role}</span> },
        { header: 'Status', render: (u) => <Badge status={u.is_active ? 'active' : 'inactive'} /> },
      ]}
      fields={[
        { name: 'username', label: 'Username', required: true, createOnly: true },
        { name: 'full_name', label: 'Full Name' },
        { name: 'password', label: 'Password (min 8 chars)', type: 'password' },
        { name: 'role', label: 'Role', type: 'select', required: true, options: ROLE_OPTIONS },
        { name: 'is_active', label: 'Active', type: 'checkbox' },
      ]}
      defaults={{ username: '', full_name: '', password: '', role: 'dispatcher', is_active: true }}
      toForm={(u) => ({ full_name: u.full_name, password: '', role: u.role, is_active: u.is_active })}
    />
  )
}

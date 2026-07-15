import ResourcePage from '../components/ResourcePage'
import { Badge } from '../components/ui'
import { createUser, listUsers, updateUser } from '../data'
import type { Profile } from '../types'

const ROLE_OPTIONS = [
  { value: 'admin', label: 'Admin' },
  { value: 'dispatcher', label: 'Dispatcher' },
  { value: 'driver', label: 'Driver' },
  { value: 'accountant', label: 'Accountant' },
  { value: 'maintenance', label: 'Maintenance' },
]

export default function Users() {
  return (
    <ResourcePage<Profile>
      title="Users"
      queryKey="users"
      list={() => listUsers()}
      create={(payload) => createUser(payload)}
      update={(id, payload) => {
        if (!payload.password) delete payload.password
        return updateUser(String(id), payload)
      }}
      searchable={false}
      columns={[
        { header: 'Email', render: (u) => <span className="font-medium">{u.email}</span> },
        { header: 'Username', render: (u) => u.username },
        { header: 'Full Name', render: (u) => u.full_name || '—' },
        { header: 'Role', render: (u) => <span className="capitalize">{u.role}</span> },
        { header: 'Status', render: (u) => <Badge status={u.is_active ? 'active' : 'inactive'} /> },
      ]}
      fields={[
        { name: 'email', label: 'Email (sign-in)', type: 'email', required: true, createOnly: true },
        { name: 'username', label: 'Display Username', createOnly: true },
        { name: 'full_name', label: 'Full Name' },
        { name: 'password', label: 'Password (min 8 chars)', type: 'password' },
        { name: 'role', label: 'Role', type: 'select', required: true, options: ROLE_OPTIONS },
        { name: 'is_active', label: 'Active', type: 'checkbox' },
      ]}
      defaults={{ email: '', username: '', full_name: '', password: '', role: 'dispatcher', is_active: true }}
      toForm={(u) => ({ full_name: u.full_name, password: '', role: u.role, is_active: u.is_active })}
    />
  )
}

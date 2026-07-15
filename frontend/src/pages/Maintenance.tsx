import { useQuery } from '@tanstack/react-query'
import { api } from '../api'
import ResourcePage from '../components/ResourcePage'
import { formatDate, money } from '../components/ui'
import type { Equipment, MaintenanceRecord } from '../types'

export default function Maintenance() {
  const { data: trucks = [] } = useQuery({
    queryKey: ['/trucks'],
    queryFn: () => api.get<Equipment[]>('/trucks').then((r) => r.data),
  })
  const { data: trailers = [] } = useQuery({
    queryKey: ['/trailers'],
    queryFn: () => api.get<Equipment[]>('/trailers').then((r) => r.data),
  })

  return (
    <ResourcePage<MaintenanceRecord>
      title="Maintenance"
      endpoint="/maintenance"
      searchable={false}
      addLabel="+ Log Repair"
      columns={[
        { header: 'Date', render: (m) => formatDate(m.date_completed) },
        { header: 'Equipment', render: (m) => <span className="font-medium">{m.equipment_unit ?? '—'}</span> },
        { header: 'Type', render: (m) => m.equipment_type },
        { header: 'Work Performed', render: (m) => <span className="line-clamp-2 max-w-md">{m.description}</span> },
        { header: 'Shop', render: (m) => m.technician_shop || '—' },
        { header: 'Cost', render: (m) => money(m.cost) },
      ]}
      fields={[
        {
          name: 'equipment_type',
          label: 'Equipment Type',
          type: 'select',
          required: true,
          options: [
            { value: 'truck', label: 'Truck' },
            { value: 'trailer', label: 'Trailer' },
          ],
        },
        {
          name: 'truck_id',
          label: 'Truck',
          type: 'select',
          options: trucks.map((t) => ({ value: String(t.id), label: t.unit_number })),
        },
        {
          name: 'trailer_id',
          label: 'Trailer',
          type: 'select',
          options: trailers.map((t) => ({ value: String(t.id), label: t.unit_number })),
        },
        { name: 'date_completed', label: 'Date Completed', type: 'date' },
        { name: 'cost', label: 'Cost ($)', type: 'number', step: '0.01' },
        { name: 'technician_shop', label: 'Technician / Shop' },
        { name: 'description', label: 'Description of Work', type: 'textarea', full: true },
      ]}
      defaults={{ equipment_type: 'truck', truck_id: '', trailer_id: '', date_completed: '', cost: '0', technician_shop: '', description: '' }}
      toForm={(m) => ({
        equipment_type: m.equipment_type,
        truck_id: m.truck_id ? String(m.truck_id) : '',
        trailer_id: m.trailer_id ? String(m.trailer_id) : '',
        date_completed: m.date_completed ?? '',
        cost: m.cost,
        technician_shop: m.technician_shop,
        description: m.description,
      })}
    />
  )
}
